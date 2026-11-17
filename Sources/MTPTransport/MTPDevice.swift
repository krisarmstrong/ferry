import CLibMTP
import DeviceKit
import Dispatch
import Foundation

/// A detected device, copied out of libmtp's detection array before that array is freed.
///
/// `@unchecked`: the struct's only pointers are the vendor and product strings, which point into
/// libmtp's static device table and are never written or freed.
struct RawDeviceRef: @unchecked Sendable {
  let raw: LIBMTP_raw_device_t
}

/// Owns one libmtp device handle; every call runs on its own serial queue.
///
/// libmtp is not thread-safe per device, so the actor's executor is a private serial queue and
/// the handle never leaves it. Methods are synchronous on that queue; callers `await` the hop.
actor MTPDevice {
  private static let libraryInitialized: Void = LIBMTP_Init()

  private let queue: DispatchSerialQueue
  private let handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
  nonisolated let info: DeviceInfo

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  /// Lists attached MTP devices. A bus with no device returns `[]`.
  static func detect() throws(TransportError) -> [RawDeviceRef] {
    _ = libraryInitialized
    var devices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
    var count: Int32 = 0
    let result = LIBMTP_Detect_Raw_Devices(&devices, &count)
    defer { free(devices) }
    switch result {
    case LIBMTP_ERROR_NONE:
      break
    case LIBMTP_ERROR_NO_DEVICE_ATTACHED:
      return []
    default:
      throw .io("detecting MTP devices failed (libmtp error \(result.rawValue))")
    }
    guard let devices else { return [] }
    return (0..<Int(count)).map { RawDeviceRef(raw: devices[$0]) }
  }

  /// Opens `raw`. Failure usually means another process (Android File Transfer, a camera
  /// importer) holds the interface, so it is reported as `.deviceBusy`.
  init(opening raw: RawDeviceRef) throws(TransportError) {
    _ = Self.libraryInitialized
    let queue = DispatchSerialQueue(label: "io.github.krisarmstrong.ferry.mtp-device")
    // Open and identify on the device's queue too, so no libmtp call for this handle ever
    // runs anywhere else.
    let opened = queue.sync { () -> (UnsafeMutablePointer<LIBMTP_mtpdevice_t>, DeviceInfo)? in
      var raw = raw.raw
      guard let handle = LIBMTP_Open_Raw_Device_Uncached(&raw) else { return nil }
      return (handle, Self.identify(handle, raw: raw))
    }
    guard let opened else { throw .deviceBusy }
    self.queue = queue
    (handle, info) = opened
  }

  isolated deinit {
    LIBMTP_Release_Device(handle)
  }

  func capabilities() -> DeviceCapabilities {
    var capabilities: DeviceCapabilities = []
    if LIBMTP_Check_Capability(handle, LIBMTP_DEVICECAP_MoveObject) != 0 {
      capabilities.insert(.move)
    }
    if LIBMTP_Check_Capability(handle, LIBMTP_DEVICECAP_CopyObject) != 0 {
      capabilities.insert(.copy)
    }
    if LIBMTP_Check_Capability(handle, LIBMTP_DEVICECAP_GetPartialObject) != 0 {
      capabilities.insert(.partialRead)
    }
    return capabilities
  }

  /// The device's storages. A locked Android phone exposes none, so an empty list or a failed
  /// read on a still-connected device is `.deviceLocked`.
  func storages() throws(TransportError) -> [(raw: UInt32, info: StorageInfo)] {
    LIBMTP_Clear_Errorstack(handle)
    if LIBMTP_Get_Storage(handle, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 {
      let error = TransportError.drained(from: handle, during: "reading storages")
      throw error == .deviceDisconnected ? error : .deviceLocked
    }
    // The storage list belongs to the device handle and is freed by LIBMTP_Release_Device.
    var result: [(raw: UInt32, info: StorageInfo)] = []
    var node = handle.pointee.storage
    while let storage = node {
      let description = Self.string(storage.pointee.StorageDescription)
      let volume = Self.string(storage.pointee.VolumeIdentifier)
      let info = StorageInfo(
        id: StorageID(device: info.id, key: "\(description)|\(volume)"),
        description: description, capacity: storage.pointee.MaxCapacity,
        free: storage.pointee.FreeSpaceInBytes)
      result.append((raw: storage.pointee.id, info: info))
      node = storage.pointee.next
    }
    guard !result.isEmpty else { throw .deviceLocked }
    return result
  }

  /// Children of `parent`; pass `PathResolver.rootParent` for the storage root.
  func list(storage: UInt32, parent: UInt32) throws(TransportError) -> [MTPEntry] {
    LIBMTP_Clear_Errorstack(handle)
    var node = LIBMTP_Get_Files_And_Folders(handle, storage, parent)
    // NULL means both "empty folder" and "failed"; only the error stack tells them apart.
    if node == nil, LIBMTP_Get_Errorstack(handle) != nil {
      throw .drained(from: handle, during: "listing folder")
    }
    var entries: [MTPEntry] = []
    while let file = node {
      entries.append(MTPEntry(file.pointee))
      node = file.pointee.next
      LIBMTP_destroy_file_t(file)
    }
    return entries
  }

  func download(objectID: UInt32, to file: URL, progress: ProgressHandler)
    throws(TransportError)
  {
    let handle = handle
    let (result, cancelled) = file.withUnsafeFileSystemRepresentation { path in
      guard let path else { return (Int32(-1), false) }
      return Self.transfer(progress: progress) { context in
        LIBMTP_Get_File_To_File(handle, objectID, path, reportProgress, context)
      }
    }
    try check(result, cancelled: cancelled, during: "downloading")
  }

  /// Uploads `file` as `name` and returns the new object's ID. `parent` may be
  /// `PathResolver.rootParent`.
  func upload(
    from file: URL, name: String, parent: UInt32, storage: UInt32, progress: ProgressHandler
  ) throws(TransportError) -> UInt32 {
    let size = try Self.localSize(of: file)
    guard let metadata = LIBMTP_new_file_t() else { throw .io("uploading failed: out of memory") }
    defer { LIBMTP_destroy_file_t(metadata) }
    // LIBMTP_destroy_file_t frees `filename`, so it must be libmtp-owned (malloc'd) memory.
    metadata.pointee.filename = strdup(name)
    metadata.pointee.filesize = size
    // 0xFFFFFFFF, not 0: libmtp redirects a parent of 0 into a "default" folder for known
    // file types on primary storage, and only passes 0xFFFFFFFF through as the root.
    metadata.pointee.parent_id = parent
    metadata.pointee.storage_id = storage
    metadata.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN

    let handle = handle
    let (result, cancelled) = file.withUnsafeFileSystemRepresentation { path in
      guard let path else { return (Int32(-1), false) }
      return Self.transfer(progress: progress) { context in
        LIBMTP_Send_File_From_File(handle, path, metadata, reportProgress, context)
      }
    }
    try check(result, cancelled: cancelled, during: "uploading")
    return metadata.pointee.item_id
  }

  /// Creates `name` under `parent` (`PathResolver.rootParent` for the root, as libmtp documents
  /// for this call) and returns its ID.
  func createFolder(name: String, parent: UInt32, storage: UInt32) throws(TransportError)
    -> UInt32
  {
    // LIBMTP_Create_Folder may rewrite the name in place on 7-bit-only devices, so it gets a copy.
    guard let buffer = strdup(name) else { throw .io("creating folder failed: out of memory") }
    defer { free(buffer) }
    let id = LIBMTP_Create_Folder(handle, buffer, parent, storage)
    guard id != 0 else { throw .drained(from: handle, during: "creating folder") }
    return id
  }

  func rename(objectID: UInt32, to name: String) throws(TransportError) {
    guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
      throw .drained(from: handle, during: "reading metadata")
    }
    defer { LIBMTP_destroy_file_t(file) }
    let result = name.withCString { LIBMTP_Set_File_Name(handle, file, $0) }
    try check(result, during: "renaming")
  }

  /// Moves `objectID` under `newParent`, which may be `PathResolver.rootParent`.
  func move(objectID: UInt32, storage: UInt32, newParent: UInt32) throws(TransportError) {
    // MoveObject names the root as 0, unlike listing and SendObjectInfo.
    let parent = newParent == PathResolver.rootParent ? 0 : newParent
    try check(LIBMTP_Move_Object(handle, objectID, storage, parent), during: "moving")
  }

  func delete(objectID: UInt32) throws(TransportError) {
    try check(LIBMTP_Delete_Object(handle, objectID), during: "deleting")
  }

  func metadata(objectID: UInt32) throws(TransportError) -> MTPEntry {
    guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
      throw .drained(from: handle, during: "reading metadata")
    }
    defer { LIBMTP_destroy_file_t(file) }
    return MTPEntry(file.pointee)
  }

  // MARK: Helpers

  private func check(_ result: Int32, cancelled: Bool = false, during operation: String)
    throws(TransportError)
  {
    guard result != 0 else { return }
    let error = TransportError.drained(from: handle, during: operation)
    throw cancelled ? .cancelled : error
  }

  /// Runs a libmtp transfer with `progress` reachable through the callback's context pointer.
  /// Returns libmtp's result and whether the handler asked to cancel.
  private static func transfer(
    progress: ProgressHandler, _ body: (UnsafeRawPointer) -> Int32
  ) -> (result: Int32, cancelled: Bool) {
    withoutActuallyEscaping(progress) { handler in
      let context = ProgressContext(handler)
      let result = withExtendedLifetime(context) {
        body(UnsafeRawPointer(Unmanaged.passUnretained(context).toOpaque()))
      }
      return (result, context.cancelled)
    }
  }

  private static func identify(
    _ handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, raw: LIBMTP_raw_device_t
  ) -> DeviceInfo {
    let serial = takeString(LIBMTP_Get_Serialnumber(handle))
    let manufacturer =
      takeString(LIBMTP_Get_Manufacturername(handle))
      ?? raw.device_entry.vendor.map {
        String(cString: $0)
      }
    let model =
      takeString(LIBMTP_Get_Modelname(handle))
      ?? raw.device_entry.product.map {
        String(cString: $0)
      }
    return DeviceInfo(
      // A device without a serial falls back to its USB location, which is not stable across
      // ports but is unique while connected.
      id: DeviceID(serial: serial ?? "usb-\(raw.bus_location)-\(raw.devnum)"),
      manufacturer: manufacturer ?? "Unknown", model: model ?? "MTP device")
  }

  /// Copies and frees a malloc'd C string from libmtp; empty strings count as absent.
  private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { free(pointer) }
    let string = String(cString: pointer)
    return string.isEmpty ? nil : string
  }

  private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
  }

  private static func localSize(of file: URL) throws(TransportError) -> UInt64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    } catch {
      throw .io(error.localizedDescription)
    }
  }
}

/// The Swift progress handler for one transfer, passed to libmtp as opaque context data.
private final class ProgressContext {
  let handler: ProgressHandler
  var cancelled = false

  init(_ handler: @escaping ProgressHandler) {
    self.handler = handler
  }
}

/// libmtp's progress callback: returning non-zero aborts the transfer.
private func reportProgress(_ sent: UInt64, _ total: UInt64, _ data: UnsafeRawPointer?) -> Int32 {
  guard let data else { return 0 }
  let context = Unmanaged<ProgressContext>.fromOpaque(data).takeUnretainedValue()
  guard context.handler(sent, total) else {
    context.cancelled = true
    return 1
  }
  return 0
}

extension MTPEntry {
  init(_ file: LIBMTP_file_t) {
    self.init(
      objectID: file.item_id,
      name: file.filename.map { String(cString: $0) } ?? "",
      isFolder: file.filetype == LIBMTP_FILETYPE_FOLDER,
      size: file.filesize,
      modified: Date(timeIntervalSince1970: TimeInterval(file.modificationdate)))
  }
}
