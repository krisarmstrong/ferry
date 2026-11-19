import DeviceKit
import Foundation

/// The fake's session operations, as a real session runs them: each takes the request's turn at
/// the device (`DeviceTurns`), and with `serialiseOperations()` they also run one at a time, as
/// MTP and ADB sessions do through their gate, so a transfer on one storage holds back a
/// request on another.
extension FakeDevice {
  /// Runs operations one at a time from now on, as a real session does.
  public func serialiseOperations() {
    serialised = true
  }

  /// Operations waiting for the one running, when serialised.
  public var operationsWaiting: Int {
    get async { await sessionGate.waiting }
  }

  private func turn<T>(_ body: () async throws(TransportError) -> T)
    async throws(TransportError) -> T
  {
    guard serialised else {
      try DeviceTurns.take()
      return try await body()
    }
    return try await sessionGate.run { () async throws(TransportError) -> T in
      try DeviceTurns.take()
      return try await body()
    }
  }

  public func storages() async throws(TransportError) -> [StorageInfo] {
    try await turn { () async throws(TransportError) in try await storagesOnDevice() }
  }

  public func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError)
    -> [RemoteItem]
  {
    try await turn { () async throws(TransportError) in
      try await listOnDevice(folder, in: storage)
    }
  }

  public func item(at path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    try await turn { () async throws(TransportError) in
      try await itemOnDevice(at: path, in: storage)
    }
  }

  @discardableResult
  public func download(
    _ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
    progress: ProgressHandler
  ) async throws(TransportError) -> Downloaded {
    try await turn { () async throws(TransportError) in
      try await downloadOnDevice(
        path, in: storage, to: file, replacing: replacing, progress: progress)
    }
  }

  public func upload(
    from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler
  ) async throws(TransportError) -> RemoteItem {
    try await turn { () async throws(TransportError) in
      try await uploadOnDevice(from: file, to: path, in: storage, progress: progress)
    }
  }

  public func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError)
    -> RemoteItem
  {
    try await turn { () async throws(TransportError) in
      try await makeFolderOnDevice(path, in: storage)
    }
  }

  public func rename(_ path: RemotePath, to newName: String, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await turn { () async throws(TransportError) in
      try await renameOnDevice(path, to: newName, in: storage)
    }
  }

  public func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID)
    async throws(TransportError) -> RemoteItem
  {
    try await turn { () async throws(TransportError) in
      try await moveOnDevice(path, toFolder: toFolder, in: storage)
    }
  }

  public func delete(_ path: RemotePath, in storage: StorageID, expecting: [RemoteItem]?)
    async throws(TransportError)
  {
    try await turn { () async throws(TransportError) in
      try await deleteOnDevice(path, in: storage, expecting: expecting)
    }
  }

  public func forgetCachedItems() async throws(TransportError) {
    try await turn { () async throws(TransportError) in try await forgetCachedItemsOnDevice() }
  }
}
