import Foundation

/// Reports bytes transferred so far and the total. Return `false` to cancel the transfer.
public typealias ProgressHandler = @Sendable (_ done: UInt64, _ total: UInt64) -> Bool

public protocol DeviceTransport: Sendable {
  /// Finds attached devices. A device this process already holds is reported without being
  /// touched.
  func scan() async throws(TransportError) -> DeviceScan
  /// Opens a device the most recent `scan()` reported in `devices`. A device this process
  /// already holds is `.deviceBusy`.
  func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession
  /// Leaves the held device `id` alone after its session closes: scans report it in `ejected`
  /// without touching it until it is unplugged or `unpark(_:)` is called.
  func park(_ id: DeviceID) async
  /// Lets the next scan try `id` again: a device reported busy, or one parked.
  func unpark(_ id: DeviceID) async
  /// Looks for `adb` again and starts its server, for a user who has just installed it. A
  /// transport without adb does nothing.
  func startADBServer() async
}

extension DeviceTransport {
  public func startADBServer() async {}
}

public protocol DeviceSession: Sendable {
  var info: DeviceInfo { get }
  /// How this session reaches the device.
  var method: ConnectionMethod { get async }
  /// Partials being written on this device. Shared by every `SafeWriter` over the session and
  /// by the session itself, so no listing reaps a partial that is still being written.
  var partials: PartialRegistry { get }
  func capabilities() async -> DeviceCapabilities
  /// A device that reports no storages is locked, so implementations throw `.deviceLocked`.
  func storages() async throws(TransportError) -> [StorageInfo]
  func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  func item(at path: RemotePath, in storage: StorageID) async throws(TransportError) -> RemoteItem
  /// Without `replacing`, a file already at `file` when the download completes is
  /// `.alreadyExists` and is left untouched.
  @discardableResult
  func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded
  /// `path` must not already exist.
  func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem
  func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  /// Deleting a folder deletes its contents. `expecting`, if given, is everything the caller
  /// checked: the item at `path` and, for a folder, every item inside it that Finder would show
  /// (partials and backups go with it unchecked). The device must still have exactly those, files
  /// by kind, size and date, folders by kind: another item at `path` is `.changedOnDevice(path)`,
  /// anything new or changed inside is `.directoryNotEmpty(path)`, and then nothing is deleted.
  func delete(_ path: RemotePath, in storage: StorageID, expecting: [RemoteItem]?)
    async throws(TransportError)
  /// Forgets whatever the session, or the library under it, remembers of the device's items, so
  /// the next reads see the device as it is now: the menu's Refresh. MTP reopens the device, since
  /// libmtp keeps the object info it first read for an object, and so never sees a file an app
  /// rewrote in place or renamed; ADB reads everything fresh and has nothing to forget.
  func forgetCachedItems() async throws(TransportError)
  func close() async
}

extension DeviceSession {
  /// Deletes whatever is at `path`, with its contents.
  public func delete(_ path: RemotePath, in storage: StorageID) async throws(TransportError) {
    try await delete(path, in: storage, expecting: nil)
  }
}

extension RemoteItem {
  /// Whether this is the item `checked` describes: a file of the same size and date, or a
  /// folder (whose date changes with what it holds).
  public func matches(_ checked: RemoteItem) -> Bool {
    kind == checked.kind
      && (kind == .folder || (size == checked.size && modified == checked.modified))
  }
}

/// A finished download: the file as the device listed it, and how many bytes arrived. They
/// differ when the device's metadata is stale (an app rewrote the file): the bytes are the
/// truth, since the device reported the transfer complete.
public struct Downloaded: Sendable, Equatable {
  public let listed: RemoteItem
  public let received: UInt64

  public init(listed: RemoteItem, received: UInt64) {
    self.listed = listed
    self.received = received
  }

  /// The file as received.
  public var item: RemoteItem {
    RemoteItem(path: listed.path, kind: listed.kind, size: received, modified: listed.modified)
  }
}
