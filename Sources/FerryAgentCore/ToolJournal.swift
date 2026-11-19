import ADBTransport
import DeviceKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "ADBTools")

/// The temporary files the tools put on devices (an APK on its way to pm, a recording before it
/// is pulled) and have not removed yet, by device, kept in the agent's Application Support.
///
/// A path is noted before the file can exist and dropped once it is removed, so one the agent
/// could not remove (the device left, the agent stopped) is still known; the next time a session
/// for the device opens, `sweep` removes it. Only paths `ADBDeviceTools.isTemporaryPath` accepts
/// are ever stored or read back, so the file can never name anything else on a device. A path a
/// tool is still using is never swept.
public actor ToolJournal {
  private let store: URL
  private var pending: [DeviceID: Set<String>]
  private var inUse: Set<String> = []

  public init(store: URL) {
    self.store = store
    pending = Self.load(store)
  }

  public static func defaultStore() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "io.github.krisarmstrong.ferry.agent/tool-files.json")
  }

  /// Notes `path` on `id` before it is created; it is in use until `release` or `removed`.
  func note(_ path: String, on id: DeviceID) {
    guard ADBDeviceTools.isTemporaryPath(path) else { return }
    pending[id, default: []].insert(path)
    inUse.insert(path)
    save()
  }

  /// The tool is done with `path`, which is gone from the device.
  func removed(_ path: String, on id: DeviceID) {
    inUse.remove(path)
    pending[id]?.remove(path)
    if pending[id]?.isEmpty == true { pending[id] = nil }
    save()
  }

  /// The tool is done with `path`, which may still be on the device: the next session sweeps it.
  func release(_ path: String) {
    inUse.remove(path)
  }

  func paths(on id: DeviceID) -> Set<String> {
    pending[id] ?? []
  }

  /// Removes the device's leftover files over `serial`, keeping any that could not be removed.
  public func sweep(_ id: DeviceID, serial: String, using tools: any ADBToolDevice) async {
    for path in (pending[id] ?? []).subtracting(inUse).sorted() {
      inUse.insert(path)
      let gone = await tools.removeTemporary(path, serial: serial)
      inUse.remove(path)
      if gone {
        log.info("removed a file a tool left on the device")
        removed(path, on: id)
      }
    }
  }

  private static func load(_ file: URL) -> [DeviceID: Set<String>] {
    guard let data = try? Data(contentsOf: file) else { return [:] }
    guard let stored = try? JSONDecoder().decode([String: [String]].self, from: data) else {
      log.error("the tool file journal is unreadable, starting empty")
      return [:]
    }
    var pending: [DeviceID: Set<String>] = [:]
    for (serial, paths) in stored where !serial.isEmpty {
      let valid = Set(paths.filter(ADBDeviceTools.isTemporaryPath))
      if valid.count != paths.count { log.error("dropped journal entries that are not tool files") }
      if !valid.isEmpty { pending[DeviceID(serial: serial)] = valid }
    }
    return pending
  }

  private func save() {
    let stored = Dictionary(
      uniqueKeysWithValues: pending.map { ($0.key.serial, $0.value.sorted()) })
    do {
      try FileManager.default.createDirectory(
        at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(stored).write(to: store, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    } catch {
      log.error("saving the tool file journal failed: \(error, privacy: .private)")
    }
  }
}
