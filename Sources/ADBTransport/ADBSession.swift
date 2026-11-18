import DeviceKit
import Foundation
import os

/// A `DeviceSession` over adb: file transfer and metadata on the sync service, rename, move,
/// folder creation and delete as toybox commands in the device's shell.
///
/// Storage-relative paths live under each storage's device folder (see `ADBStorages`). Public
/// operations run one at a time through `gate`, so a check and the action it guards are never
/// split by another operation; they must not call each other, as the gate is not reentrant. One
/// sync connection is kept open between operations and replaced after any error, since a failed
/// request ends it. Once the device is gone the session fails every later call at once.
///
/// adbd's `SEND` replaces an existing file and creates missing folders, and toybox `mv` moves
/// onto an existing folder by going inside it: every write is checked against a fresh listing
/// first, under the gate, and `mv` runs with `-n` and is confirmed afterwards.
public actor ADBSession: DeviceSession {
  static let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBSession")

  public nonisolated let info: DeviceInfo
  public nonisolated let partials: PartialRegistry
  /// Over the network when `serial` is a `host:port`, over USB otherwise.
  public nonisolated let method: ConnectionMethod
  let host: ADBHost
  /// The adb server's name for the device (`host:port` over Wi-Fi), which need not be
  /// `info.id.serial` (`ro.serialno`).
  let serial: String
  private let features: Set<String>
  private let gate = OperationGate()
  private var sync: ADBSync?
  /// The storage keys the device had when they were last read.
  private var knownStorages: Set<String> = []
  /// The device's own spelling of each name, by folder (see `ADBSession+Names.swift`).
  var rawNames: [[UInt8]: [String: String]] = [:]
  private var disconnected = false
  /// Tells the transport the device is free again; runs once, when the session ends.
  private var onRelease: (@Sendable () async -> Void)?

  public init(
    host: ADBHost, serial: String, info: DeviceInfo, features: Set<String>,
    partials: PartialRegistry = PartialRegistry(),
    onRelease: @escaping @Sendable () async -> Void = {}
  ) {
    self.host = host
    self.serial = serial
    method = ADBWire.isWireless(serial) ? .wifiADB : .usbADB
    self.info = info
    self.features = features
    self.partials = partials
    self.onRelease = onRelease
  }

  isolated deinit {
    // Dropped without `close()`.
    if let onRelease { Task { await onRelease() } }
  }

  /// `.copy` stands for the device's own `cp`; there is no partial read over sync.
  public func capabilities() async -> DeviceCapabilities {
    await gate.run { () async -> DeviceCapabilities in disconnected ? [] : [.move, .copy] }
  }

  public func storages() async throws(TransportError) -> [StorageInfo] {
    try await operation { () throws(TransportError) in
      let storages = try await refreshStorages()
      guard !storages.isEmpty else { throw .deviceLocked }
      return storages
    }
  }

  public func close() async {
    await gate.run { () async in
      disconnected = true
      await dropSync()
      await released()
    }
  }

  // MARK: Plumbing

  /// Runs `body` as one gated operation. A `.deviceDisconnected` from it ends the session and
  /// releases the device, so the transport can open it afresh once it is back.
  func operation<T>(_ body: () async throws(TransportError) -> T)
    async throws(TransportError) -> T
  {
    try await gate.run { () async throws(TransportError) -> T in
      guard !disconnected else { throw .deviceDisconnected }
      do throws(TransportError) {
        return try await body()
      } catch {
        if error == .deviceDisconnected {
          disconnected = true
          await dropSync()
          await released()
        }
        throw error
      }
    }
  }

  /// One gated operation on `storage`, given its device folder. A storage whose folder has gone
  /// (a card ejected, storage unmounted) is `.storageNotFound`, never `.notFound` for an item in
  /// it: FileProvider deletes the local copy of an item reported missing.
  func operation<T>(on storage: StorageID, _ body: (String) async throws(TransportError) -> T)
    async throws(TransportError) -> T
  {
    try await operation { () throws(TransportError) -> T in
      let root = try await root(for: storage)
      do throws(TransportError) {
        return try await body(root)
      } catch {
        guard case .notFound = error else { throw error }
        let mounted = try await adb(Step("reading", .root)) { () async throws(ADBError) in
          try await syncing { (sync) async throws(ADBError) in try await sync.stat(root) }
        }
        guard mounted?.isDirectory == true else {
          knownStorages.remove(storage.key)
          throw .storageNotFound(storage.key)
        }
        throw error
      }
    }
  }

  private func released() async {
    guard let onRelease else { return }
    self.onRelease = nil
    await onRelease()
  }

  private func dropSync() async {
    let open = sync
    sync = nil
    await open?.quit()
  }

  private func refreshStorages() async throws(TransportError) -> [StorageInfo] {
    let storages = try await discoverStorages()
    knownStorages = Set(storages.map(\.id.key))
    return storages
  }

  /// The device folder of `storage`, reading the device's storages once if the key is unknown.
  func root(for storage: StorageID) async throws(TransportError) -> String {
    guard storage.device == info.id, let root = ADBStorages.root(forKey: storage.key) else {
      throw .storageNotFound(storage.key)
    }
    if !knownStorages.contains(storage.key) { _ = try await refreshStorages() }
    guard knownStorages.contains(storage.key) else { throw .storageNotFound(storage.key) }
    return root
  }

  /// Runs `body` on the open sync connection, opening one if needed. A request that fails for
  /// any reason but a refused argument has ended the connection, so it is let go.
  ///
  /// adbd keeps a sync connection until it is told to quit, and every failure drops it here, so
  /// a kept connection that closes was ended by its transport: the device left, or the server
  /// stopped, perhaps to come straight back (`adb kill-server`). The device may answer again at
  /// once, but on a new transport, so this session's route is gone either way.
  func syncing<T>(_ body: (ADBSync) async throws(ADBError) -> T) async throws(ADBError) -> T {
    let open: ADBSync
    let kept = sync != nil
    if let sync {
      open = sync
    } else {
      open = ADBSync(stream: try await host.connect(serial, service: "sync:"), features: features)
      sync = open
    }
    do throws(ADBError) {
      return try await body(open)
    } catch {
      if case .invalidArgument = error {} else { sync = nil }
      if kept, error == .connectionClosed { throw .deviceGone(serial) }
      throw error
    }
  }

  /// Runs a toybox command; a non-zero status is returned, not thrown.
  func run(_ program: String, _ args: [String], _ step: Step) async throws(TransportError)
    -> ADBShellResult
  {
    try await adb(step) { () async throws(ADBError) in
      try await host.run(serial: serial, command: ADBShell.command(program, args))
    }
  }

  /// Runs a toybox command and turns a non-zero status into the error its message names.
  func shell(_ program: String, _ args: [String], _ step: Step) async throws(TransportError) {
    let result = try await run(program, args, step)
    guard result.status != 0 else { return }
    throw await deviceFailure(Self.message(of: result), step)
  }

  /// A failed command's output, stderr first. Output that is not UTF-8 (it names a file whose
  /// name is not) is read as Latin-1, which keeps every byte and the ASCII errno text that ends
  /// it.
  static func message(of result: ADBShellResult) -> String {
    [result.stderr, result.stdout]
      .map { String(bytes: $0, encoding: .utf8) ?? String(bytes: $0, encoding: .isoLatin1) ?? "" }
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: Errors

extension ADBSession {
  /// What an operation was doing when it failed, for the error it reports: `path` is what it
  /// acted on, `target` what it was creating.
  struct Step {
    let name: String
    let path: RemotePath
    let target: RemotePath?

    init(_ name: String, _ path: RemotePath, target: RemotePath? = nil) {
      self.name = name
      self.path = path
      self.target = target
    }
  }

  func adb<T>(_ step: Step, _ body: () async throws(ADBError) -> T) async throws(TransportError)
    -> T
  {
    do throws(ADBError) {
      return try await body()
    } catch {
      throw await failure(error, step)
    }
  }

  /// How an `ADBError` reaches the caller:
  ///
  /// | `ADBError` | `TransportError` |
  /// |---|---|
  /// | `deviceGone`, `serverUnavailable`, `adbNotInstalled` | `.deviceDisconnected` |
  /// | `failed("device offline…")`, `failed("device unauthorized…")` | `.deviceDisconnected` |
  /// | `cancelled` (the progress handler stopped a transfer) | `.cancelled`, as MTPSession's |
  /// | `invalidArgument` (a path the sync service cannot carry) | `.invalidName(path)` |
  /// | `failed(message)`, from the device | by its `strerror` text (`fromDevice`) |
  /// | `connectionClosed`, `protocolViolation` | `.io` |
  ///
  /// A kept sync connection that closes is `deviceGone` already (see `syncing`).
  ///
  /// Any `.io` is a lost device instead when the server no longer knows the device.
  func failure(_ error: ADBError, _ step: Step) async -> TransportError {
    switch error {
    case .deviceGone, .serverUnavailable, .adbNotInstalled:
      return .deviceDisconnected
    case .cancelled:
      return .cancelled
    case .invalidArgument:
      return .invalidName(step.path.description)
    case .failed(let message)
    where message.hasPrefix("device offline") || message.hasPrefix("device unauthorized"):
      return .deviceDisconnected
    case .failed(let message):
      return await deviceFailure(message, step)
    case .connectionClosed, .protocolViolation:
      return await reachable() ? .io("\(step.name) failed: \(error)") : .deviceDisconnected
    }
  }

  /// A message from the device (a sync `FAIL` or a command's output) as a `TransportError`.
  func deviceFailure(_ message: String, _ step: Step) async -> TransportError {
    let error = TransportError.fromDevice(message, step)
    if case .io = error, await !reachable() { return .deviceDisconnected }
    return error
  }

  func reachable() async -> Bool {
    do {
      _ = try await host.features(serial)
      return true
    } catch {
      return false
    }
  }
}

extension TransportError {
  /// Classifies a device's message by the `strerror` text toybox's `perror_msg` and adbd's
  /// `FAIL` end it with. Only the end is read: the path before it may be any name, even one
  /// that reads like an error.
  static func fromDevice(_ message: String, _ step: ADBSession.Step) -> TransportError {
    let says = { (text: String) in message.hasSuffix(": " + text) }
    if says("No such file or directory") || says("Not a directory") {
      return .notFound(step.path)
    }
    if says("File exists") { return .alreadyExists(step.target ?? step.path) }
    if says("Is a directory") {
      return step.target.map(TransportError.alreadyExists) ?? .notFound(step.path)
    }
    if says("Directory not empty") { return .directoryNotEmpty(step.path) }
    // Neither figure is known; the caller fills in what it knows, as with MTP.
    if says("No space left on device") { return .insufficientSpace(needed: 0, free: 0) }
    return .io("\(step.name) failed: \(message)")
  }
}
