import DeviceKit
import Foundation

@testable import MTPTransport

/// An in-memory MTP device that, like the real thing, knows only object IDs. It refuses to
/// delete a non-empty folder and records every mutating call, so tests can see what a session
/// sent and in which order. Uploads suspend partway, so a session that lets two operations
/// interleave shows up as an overlapping device call.
actor StubMTPDevice: MTPDeviceOperations {
  enum Call: Equatable {
    case upload(name: String, parent: UInt32)
    case createFolder(name: String, parent: UInt32)
    case rename(UInt32, name: String)
    case move(UInt32, parent: UInt32)
    case delete(UInt32)
  }

  struct Object {
    var parent: UInt32
    var name: String
    let isFolder: Bool
    var data: Data
    let modified: Date
  }

  static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  nonisolated let info: DeviceInfo
  private let storageList: [(raw: UInt32, info: StorageInfo)]
  private let deviceCapabilities: DeviceCapabilities
  private(set) var objects: [UInt32: Object] = [:]
  private(set) var calls: [Call] = []
  private(set) var closed = false
  /// Every device call, mutating or not, including ones that threw.
  private(set) var callCount = 0
  /// Whether a call arrived while an upload was still in progress.
  private(set) var overlapped = false
  private var uploading = 0
  /// Set by `unplug()`: every call throws `.deviceDisconnected`, as a lost USB link does.
  private var unplugged = false
  /// Runs when an upload starts, with the name it was sent.
  private var uploadHook: (@Sendable (String) async -> Void)?
  /// A file that something else creates at a URL while the next download is in progress.
  private var downloadInterloper: (url: URL, data: Data)?
  private var nextID: UInt32 = 100
  /// Uploads keep at most this many bytes and still report success.
  private var uploadLimit: Int?
  /// The next upload stores its object, then throws this.
  private var uploadFailure: TransportError?
  /// Downloads write at most this many bytes and still report success.
  private var downloadLimit: Int?
  /// Downloads cut short this many more times, then write everything.
  private var shortDownloads = 0
  /// Sizes the device reports for objects instead of their real ones, as stale metadata does.
  private var reportedSizes: [UInt32: UInt64] = [:]
  private(set) var downloadCount = 0
  /// Folder listings the session asked for.
  private(set) var listCount = 0
  /// The next download writes half the object, then throws this.
  private var downloadFailure: TransportError?
  /// Names the device stores differently from what it was sent, as a FAT card or 7-bit
  /// firmware does.
  private var storedNames: [String: String] = [:]

  init(
    info: DeviceInfo, storages: [(raw: UInt32, info: StorageInfo)],
    capabilities: DeviceCapabilities
  ) {
    self.info = info
    self.storageList = storages
    self.deviceCapabilities = capabilities
  }

  // MARK: Test controls

  @discardableResult
  func addFolder(_ name: String, parent: UInt32) -> UInt32 {
    insert(Object(parent: parent, name: name, isFolder: true, data: Data(), modified: Self.epoch))
  }

  @discardableResult
  func addFile(_ name: String, parent: UInt32, data: Data) -> UInt32 {
    insert(Object(parent: parent, name: name, isFolder: false, data: data, modified: Self.epoch))
  }

  /// Changes a file's contents as an app on the device would, with no call from the session.
  func replaceData(of id: UInt32, with data: Data) {
    objects[id]?.data = data
  }

  /// Deletes an object as an app on the device would, with no call from the session.
  func removeObject(_ id: UInt32) {
    objects[id] = nil
  }

  /// Moves an object as an app on the device would, keeping its ID.
  func moveObject(_ id: UInt32, to parent: UInt32) {
    objects[id]?.parent = parent
  }

  /// Renames an object as an app on the device would, keeping its ID.
  func renameObject(_ id: UInt32, to name: String) {
    objects[id]?.name = name
  }

  func limitUploads(to bytes: Int) {
    uploadLimit = bytes
  }

  func failNextUpload(with error: TransportError) {
    uploadFailure = error
  }

  /// The next `count` downloads write half the object and still report success.
  func cutShortNextDownloads(_ count: Int) {
    shortDownloads = count
  }

  /// The device lists and describes `id` as `size` bytes, whatever it holds.
  func reportSize(_ size: UInt64, for id: UInt32) {
    reportedSizes[id] = size
  }

  func limitDownloads(to bytes: Int) {
    downloadLimit = bytes
  }

  func failNextDownload(with error: TransportError) {
    downloadFailure = error
  }

  func storeName(_ requested: String, as actual: String) {
    storedNames[requested] = actual
  }

  func unplug() {
    unplugged = true
  }

  func resetCallCount() {
    callCount = 0
  }

  func onUpload(_ hook: @escaping @Sendable (String) async -> Void) {
    uploadHook = hook
  }

  /// The next download, once its bytes are written, finds `data` created at `url`.
  func createDuringDownload(at url: URL, data: Data) {
    downloadInterloper = (url, data)
  }

  var uploadCount: Int {
    calls.filter { if case .upload = $0 { true } else { false } }.count
  }

  /// Every name the session sent to the device.
  var sentNames: [String] {
    calls.compactMap {
      switch $0 {
      case .upload(let name, _), .createFolder(let name, _), .rename(_, let name): name
      case .move, .delete: nil
      }
    }
  }

  func children(of parent: UInt32) -> [String] {
    objects.filter { $0.value.parent == parent }.map(\.value.name).sorted()
  }

  // MARK: MTPDeviceOperations

  func capabilities() -> DeviceCapabilities {
    record()
    return deviceCapabilities
  }

  func storages() throws(TransportError) -> [(raw: UInt32, info: StorageInfo)] {
    record()
    try requireOpen()
    return storageList
  }

  func list(storage: UInt32, parent: UInt32) throws(TransportError) -> [MTPEntry] {
    record()
    listCount += 1
    try requireOpen()
    return objects.filter { $0.value.parent == parent }.map { entry($0.key, $0.value) }
      .sorted { $0.objectID < $1.objectID }
  }

  func download(objectID: UInt32, to file: URL, progress: ProgressHandler)
    throws(TransportError)
  {
    let object = try object(objectID)
    let failure = downloadFailure
    downloadFailure = nil
    var data = object.data
    downloadCount += 1
    if let downloadLimit { data = data.prefix(downloadLimit) }
    if shortDownloads > 0 {
      shortDownloads -= 1
      data = data.prefix(data.count / 2)
    }
    if failure != nil { data = data.prefix(data.count / 2) }
    do { try data.write(to: file) } catch { throw .io(error.localizedDescription) }
    if let interloper = downloadInterloper {
      downloadInterloper = nil
      do { try interloper.data.write(to: interloper.url) } catch {
        throw .io(error.localizedDescription)
      }
    }
    if let failure { throw failure }
  }

  func upload(
    from file: URL, name: String, parent: UInt32, storage: UInt32, progress: ProgressHandler
  ) async throws(TransportError) -> UInt32 {
    record()
    try requireOpen()
    uploading += 1
    defer { uploading -= 1 }
    await uploadHook?(name)
    await Task.yield()
    calls.append(.upload(name: name, parent: parent))
    var data: Data
    do { data = try Data(contentsOf: file) } catch { throw .io(error.localizedDescription) }
    if let uploadLimit { data = data.prefix(uploadLimit) }
    let id = insert(
      Object(
        parent: parent, name: storedNames[name] ?? name, isFolder: false, data: data,
        modified: Self.epoch))
    if let failure = uploadFailure {
      uploadFailure = nil
      throw failure
    }
    return id
  }

  func createFolder(name: String, parent: UInt32, storage: UInt32) throws(TransportError)
    -> UInt32
  {
    record()
    try requireOpen()
    calls.append(.createFolder(name: name, parent: parent))
    return addFolder(storedNames[name] ?? name, parent: parent)
  }

  func rename(objectID: UInt32, to name: String) throws(TransportError) {
    _ = try object(objectID)
    calls.append(.rename(objectID, name: name))
    objects[objectID]?.name = storedNames[name] ?? name
  }

  func move(objectID: UInt32, storage: UInt32, newParent: UInt32) throws(TransportError) {
    _ = try object(objectID)
    calls.append(.move(objectID, parent: newParent))
    objects[objectID]?.parent = newParent
  }

  func delete(objectID: UInt32) throws(TransportError) {
    _ = try object(objectID)
    guard !objects.values.contains(where: { $0.parent == objectID }) else {
      throw .io("deleting failed: folder not empty")
    }
    calls.append(.delete(objectID))
    objects[objectID] = nil
  }

  func metadata(objectID: UInt32) throws(TransportError) -> MTPEntry {
    entry(objectID, try object(objectID))
  }

  func close() {
    record()
    closed = true
  }

  // MARK: Helpers

  private func insert(_ object: Object) -> UInt32 {
    nextID += 1
    objects[nextID] = object
    return nextID
  }

  private func record() {
    callCount += 1
    if uploading > 0 { overlapped = true }
  }

  private func requireOpen() throws(TransportError) {
    if closed || unplugged { throw .deviceDisconnected }
  }

  /// Every object-ID call goes through here, so it is recorded once.
  private func object(_ id: UInt32) throws(TransportError) -> Object {
    record()
    try requireOpen()
    guard let object = objects[id] else { throw .io("no object \(id)") }
    return object
  }

  private func entry(_ id: UInt32, _ object: Object) -> MTPEntry {
    MTPEntry(
      objectID: id, parent: object.parent, name: object.name, isFolder: object.isFolder,
      size: reportedSizes[id] ?? UInt64(object.data.count), modified: object.modified)
  }
}
