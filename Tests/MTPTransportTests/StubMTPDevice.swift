import DeviceKit
import Foundation

@testable import MTPTransport

/// An in-memory MTP device that, like the real thing, knows only object IDs. It refuses to
/// delete a non-empty folder and records every mutating call, so tests can see what a session
/// sent and in which order.
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
  private var nextID: UInt32 = 100
  /// Uploads keep at most this many bytes and still report success.
  private var uploadLimit: Int?
  /// The next upload stores its object, then throws this.
  private var uploadFailure: TransportError?

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

  func limitUploads(to bytes: Int) {
    uploadLimit = bytes
  }

  func failNextUpload(with error: TransportError) {
    uploadFailure = error
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

  func capabilities() -> DeviceCapabilities { deviceCapabilities }

  func storages() throws(TransportError) -> [(raw: UInt32, info: StorageInfo)] {
    try requireOpen()
    return storageList
  }

  func list(storage: UInt32, parent: UInt32) throws(TransportError) -> [MTPEntry] {
    try requireOpen()
    return objects.filter { $0.value.parent == parent }.map { Self.entry($0.key, $0.value) }
      .sorted { $0.objectID < $1.objectID }
  }

  func download(objectID: UInt32, to file: URL, progress: ProgressHandler)
    throws(TransportError)
  {
    let object = try object(objectID)
    do { try object.data.write(to: file) } catch { throw .io(error.localizedDescription) }
  }

  func upload(
    from file: URL, name: String, parent: UInt32, storage: UInt32, progress: ProgressHandler
  ) throws(TransportError) -> UInt32 {
    try requireOpen()
    calls.append(.upload(name: name, parent: parent))
    var data: Data
    do { data = try Data(contentsOf: file) } catch { throw .io(error.localizedDescription) }
    if let uploadLimit { data = data.prefix(uploadLimit) }
    let id = insert(
      Object(parent: parent, name: name, isFolder: false, data: data, modified: Self.epoch))
    if let failure = uploadFailure {
      uploadFailure = nil
      throw failure
    }
    return id
  }

  func createFolder(name: String, parent: UInt32, storage: UInt32) throws(TransportError)
    -> UInt32
  {
    try requireOpen()
    calls.append(.createFolder(name: name, parent: parent))
    return addFolder(name, parent: parent)
  }

  func rename(objectID: UInt32, to name: String) throws(TransportError) {
    _ = try object(objectID)
    calls.append(.rename(objectID, name: name))
    objects[objectID]?.name = name
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
    Self.entry(objectID, try object(objectID))
  }

  func close() {
    closed = true
  }

  // MARK: Helpers

  private func insert(_ object: Object) -> UInt32 {
    nextID += 1
    objects[nextID] = object
    return nextID
  }

  private func requireOpen() throws(TransportError) {
    if closed { throw .deviceDisconnected }
  }

  private func object(_ id: UInt32) throws(TransportError) -> Object {
    try requireOpen()
    guard let object = objects[id] else { throw .io("no object \(id)") }
    return object
  }

  private static func entry(_ id: UInt32, _ object: Object) -> MTPEntry {
    MTPEntry(
      objectID: id, name: object.name, isFolder: object.isFolder,
      size: UInt64(object.data.count), modified: object.modified)
  }
}
