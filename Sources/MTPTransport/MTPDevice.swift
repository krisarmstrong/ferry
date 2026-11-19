import CLibMTP
import DeviceKit
import Dispatch
import Foundation
import os

/// A device for libmtp to open, built by `MTPDeviceTable` from the IOKit registry.
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
/// Each operation clears libmtp's error stack first, so a failure drains only its own errors.
actor MTPDevice {
  static let libraryInitialized: Void = LIBMTP_Init()
  private static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "MTPDevice")

  private let queue: DispatchSerialQueue
  /// `nil` once closed, or once an operation found the device gone; every operation then
  /// throws `.deviceDisconnected`.
  private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
  /// The device's IOKit registry entry, to tell a lost link from a protocol error without USB
  /// I/O. A replug or USB mode switch gets a new entry even at the same address.
  private let registryID: UInt64
  /// What the handle was opened from, to open it again (see `reopen()`).
  private let raw: RawDeviceRef
  nonisolated let info: DeviceInfo

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  /// Opens `raw`. Failure usually means another process (Android File Transfer, a camera
  /// importer) holds the interface, so it is reported as `.deviceBusy`.
  static func open(_ raw: RawDeviceRef, registryID: UInt64) async throws(TransportError)
    -> MTPDevice
  {
    let queue = DispatchSerialQueue(label: "io.github.krisarmstrong.ferry.mtp-device")
    // Open and identify on the device's queue too, so no libmtp call for this handle ever
    // runs anywhere else.
    guard let opened = await DeviceOpener(queue: queue).open(raw) else { throw .deviceBusy }
    return MTPDevice(queue: queue, opened: opened, raw: raw, registryID: registryID)
  }

  private init(
    queue: DispatchSerialQueue, opened: OpenedHandle, raw: RawDeviceRef, registryID: UInt64
  ) {
    self.queue = queue
    handle = opened.handle
    info = opened.info
    self.raw = raw
    self.registryID = registryID
  }

  /// Releases the handle and opens the same enumeration of the device again, on this queue.
  /// libmtp keeps the object info it first read for each object until the device is opened
  /// again, so this is how a Refresh sees files changed on the device. The device must still be
  /// attached and answer as the same device; otherwise, or if another app took it meanwhile,
  /// it is gone for this session.
  func reopen() throws(TransportError) {
    guard handle != nil, isStillAttached() else {
      close()
      throw .deviceDisconnected
    }
    close()
    guard let opened = DeviceOpener.openNow(raw), opened.info.id == info.id else {
      Self.log.error("reopening the device failed")
      throw .deviceDisconnected
    }
    handle = opened.handle
  }

  isolated deinit {
    close()
  }

  func capabilities() -> DeviceCapabilities {
    guard let handle else { return [] }
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
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    // 1 is success with storage IDs only (placeholder descriptions); only -1 is failure.
    if LIBMTP_Get_Storage(handle, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0 {
      let entries = drainErrorStack(handle)
      let detail =
        entries.isEmpty
        ? "empty error stack" : entries.map { "\($0.code): \($0.text)" }.joined(separator: "; ")
      Self.log.error("reading storages failed: \(detail, privacy: .public)")
      throw closingIfGone(
        .classify(
          entries, during: "reading storages", generalMeansLocked: true,
          deviceStillPresent: isStillAttached))
    }
    // The storage list belongs to the device handle and is freed by LIBMTP_Release_Device.
    var storages: [RawStorage] = []
    var capacities: [(capacity: UInt64, free: UInt64)] = []
    var node = handle.pointee.storage
    while let storage = node {
      storages.append(
        RawStorage(
          raw: storage.pointee.id,
          description: storage.pointee.StorageDescription.map { String(cString: $0) },
          volume: storage.pointee.VolumeIdentifier.map { String(cString: $0) },
          fileSystem: storage.pointee.FilesystemType, type: storage.pointee.StorageType))
      capacities.append((storage.pointee.MaxCapacity, storage.pointee.FreeSpaceInBytes))
      node = storage.pointee.next
    }
    guard !storages.isEmpty else { throw .deviceLocked }
    let keys = storageKeys(for: storages)
    let former = formerStorageKeys(for: storages)
    for storage in storages {
      // How each storage was keyed, so the method-neutral keys can be checked against real
      // devices. Description, volume and key can carry a user's volume label: private.
      let id = "\(String(format: "%08X", storage.raw)) type \(storage.type)"
      let named = "\(storage.description ?? "nil")|\(storage.volume ?? "nil")"
      let key = keys[storage.raw] ?? ""
      Self.log.info(
        "storage \(id, privacy: .public): \(named, privacy: .private) as \(key, privacy: .private)")
    }
    return zip(storages, capacities).map { storage, space in
      let key = keys[storage.raw] ?? ""
      let formerKey = former[storage.raw].flatMap { $0 == key ? nil : $0 }
      let info = StorageInfo(
        id: StorageID(device: info.id, key: key),
        description: storage.description ?? "", capacity: space.capacity, free: space.free,
        isFATLike: storage.fileSystem == Self.dcfFileSystem, formerKey: formerKey)
      return (raw: storage.raw, info: info)
    }
  }

  /// Children of `parent`; pass `PathResolver.rootParent` for the storage root.
  func list(storage: UInt32, parent: UInt32) throws(TransportError) -> [MTPEntry] {
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    var node = LIBMTP_Get_Files_And_Folders(handle, storage, parent)
    var entries: [MTPEntry] = []
    while let file = node {
      entries.append(MTPEntry(file.pointee))
      node = file.pointee.next
      LIBMTP_destroy_file_t(file)
    }
    do {
      return try completeListing(
        entries, errors: drainErrorStack(handle), deviceStillPresent: isStillAttached)
    } catch {
      throw closingIfGone(error)
    }
  }

  func download(objectID: UInt32, to file: URL, progress: ProgressHandler)
    throws(TransportError)
  {
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
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
    let handle = try openHandle()
    let size = try LocalFile.regularFileSize(file)
    LIBMTP_Clear_Errorstack(handle)
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

    let (result, cancelled) = file.withUnsafeFileSystemRepresentation { path in
      guard let path else { return (Int32(-1), false) }
      return Self.transfer(progress: progress) { context in
        LIBMTP_Send_File_From_File(handle, path, metadata, reportProgress, context)
      }
    }
    do {
      try check(result, cancelled: cancelled, during: "uploading")
    } catch .insufficientSpace {
      throw .insufficientSpace(needed: size, free: 0)
    }
    return metadata.pointee.item_id
  }

  /// Creates `name` under `parent` (`PathResolver.rootParent` for the root, as libmtp documents
  /// for this call) and returns its ID.
  func createFolder(name: String, parent: UInt32, storage: UInt32) throws(TransportError)
    -> UInt32
  {
    // LIBMTP_Create_Folder may rewrite the name in place on 7-bit-only devices, so it gets a copy.
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    guard let buffer = strdup(name) else { throw .io("creating folder failed: out of memory") }
    defer { free(buffer) }
    let id = LIBMTP_Create_Folder(handle, buffer, parent, storage)
    guard id != 0 else { throw failure(during: "creating folder") }
    return id
  }

  func rename(objectID: UInt32, to name: String) throws(TransportError) {
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
      throw failure(during: "reading metadata")
    }
    defer { LIBMTP_destroy_file_t(file) }
    let result = name.withCString { LIBMTP_Set_File_Name(handle, file, $0) }
    try check(result, during: "renaming")
  }

  /// Moves `objectID` under `newParent`, which may be `PathResolver.rootParent`.
  func move(objectID: UInt32, storage: UInt32, newParent: UInt32) throws(TransportError) {
    // MoveObject names the root as 0, unlike listing and SendObjectInfo.
    let parent = newParent == PathResolver.rootParent ? 0 : newParent
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    try check(LIBMTP_Move_Object(handle, objectID, storage, parent), during: "moving")
  }

  func delete(objectID: UInt32) throws(TransportError) {
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    try check(LIBMTP_Delete_Object(handle, objectID), during: "deleting")
  }

  func metadata(objectID: UInt32) throws(TransportError) -> MTPEntry {
    let handle = try openHandle()
    LIBMTP_Clear_Errorstack(handle)
    guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
      throw failure(during: "reading metadata")
    }
    defer { LIBMTP_destroy_file_t(file) }
    return MTPEntry(file.pointee)
  }

  /// PTP's FilesystemType for DCF, the FAT-based camera filesystem: the only FAT MTP names.
  private static let dcfFileSystem: UInt16 = 0x0003

  // MARK: Helpers

  private func check(_ result: Int32, cancelled: Bool = false, during operation: String)
    throws(TransportError)
  {
    guard result != 0 else { return }
    let error = failure(during: operation)
    throw cancelled ? .cancelled : error
  }

  private func openHandle() throws(TransportError) -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
    guard let handle else { throw .deviceDisconnected }
    return handle
  }

  private func failure(during operation: String) -> TransportError {
    guard let handle else { return .deviceDisconnected }
    return closingIfGone(
      .classify(drainErrorStack(handle), during: operation, deviceStillPresent: isStillAttached))
  }

  /// Releases the handle once the device is gone, so every later call fails at once in
  /// `openHandle` instead of timing out on USB.
  private func closingIfGone(_ error: TransportError) -> TransportError {
    if error == .deviceDisconnected { close() }
    return error
  }

  /// Whether this enumeration of the device is still attached, from the IOKit registry, with no
  /// USB I/O. A device that enumerated again (unplugged and replugged, or switched from charging
  /// to file transfer) has a new entry, so a handle to the old one reads as gone, not locked.
  private func isStillAttached() -> Bool {
    USBRegistry.isAttached(registryID: registryID)
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

  fileprivate static func identify(
    _ handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, raw: LIBMTP_raw_device_t
  ) -> DeviceInfo {
    let serial = takeString(LIBMTP_Get_Serialnumber(handle))
    let fallback = describe(RawDeviceRef(raw: raw))
    return DeviceInfo(
      // A device without a serial falls back to its USB location, which is not stable across
      // ports but is unique while connected.
      id: serial.map(DeviceID.init(serial:)) ?? fallback.id,
      manufacturer: takeString(LIBMTP_Get_Manufacturername(handle)) ?? fallback.manufacturer,
      model: takeString(LIBMTP_Get_Modelname(handle)) ?? fallback.model)
  }

  /// Names a device from its USB location and libmtp's device table, without opening it.
  static func describe(_ raw: RawDeviceRef) -> DeviceInfo {
    let entry = raw.raw.device_entry
    return DeviceInfo(
      id: DeviceID(serial: "usb-\(raw.raw.bus_location)-\(raw.raw.devnum)"),
      manufacturer: entry.vendor.map { String(cString: $0) } ?? "Unknown",
      model: entry.product.map { String(cString: $0) } ?? "MTP device")
  }

  /// Copies and frees a malloc'd C string from libmtp; empty strings count as absent.
  private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { free(pointer) }
    let string = String(cString: pointer)
    return string.isEmpty ? nil : string
  }
}

extension MTPDevice {
  /// Releases the USB interface now, so the device can be opened again at once. Idempotent.
  func close() {
    guard let handle else { return }
    LIBMTP_Release_Device(handle)
    self.handle = nil
  }
}

/// A handle just opened, on its way from `DeviceOpener` to the `MTPDevice` that owns it.
///
/// `@unchecked`: the handle is used only on the device's queue, before and after the hand-off,
/// and nothing else keeps it.
private struct OpenedHandle: @unchecked Sendable {
  let handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
  let info: DeviceInfo
}

/// Runs the open on a device's queue before the `MTPDevice` that will own the handle exists.
private actor DeviceOpener {
  private let queue: DispatchSerialQueue

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(queue: DispatchSerialQueue) {
    self.queue = queue
  }

  func open(_ raw: RawDeviceRef) -> OpenedHandle? {
    Self.openNow(raw)
  }

  /// Opens `raw` on the calling thread, which must be the device's queue.
  nonisolated static func openNow(_ raw: RawDeviceRef) -> OpenedHandle? {
    _ = MTPDevice.libraryInitialized
    var raw = raw.raw
    guard let handle = LIBMTP_Open_Raw_Device_Uncached(&raw) else { return nil }
    return OpenedHandle(handle: handle, info: MTPDevice.identify(handle, raw: raw))
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
      parent: file.parent_id,
      name: file.filename.map { String(cString: $0) } ?? "",
      isFolder: file.filetype == LIBMTP_FILETYPE_FOLDER,
      size: file.filesize,
      modified: Date(timeIntervalSince1970: TimeInterval(file.modificationdate)))
  }
}
