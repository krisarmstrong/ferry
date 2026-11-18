import DeviceKit
import FerryIPC
import Foundation

/// The copy the agent keeps of the Mac's contents when they were made from a version of the file
/// the device no longer has: the device's file stays, and the Mac's goes up beside it.
enum ConflictCopy {
  /// Uploads `scratch` beside `path` under the first free conflict name.
  static func upload(
    _ scratch: URL, beside path: RemotePath, _ route: DomainController.Route
  ) async throws(TransportError) -> RemoteItem {
    let (parent, name) = (path.parent ?? .root, path.name ?? "")
    for attempt in 1...maxAttempts {
      let copy = try parent.appending(self.name(for: name, attempt: attempt))
      do {
        return try await route.writer.write(
          from: scratch, to: copy, in: route.storage, replacing: false,
          progress: AgentService.ignoreProgress)
      } catch .alreadyExists where attempt < maxAttempts {
        continue
      }
    }
    throw .alreadyExists(path)
  }

  /// `report (conflict from Mac).txt`, then `report (conflict from Mac 2).txt` and so on. The
  /// marker goes before the last extension, so the copy opens in the same app. A name that
  /// starts with its only dot (`.profile`) has no extension.
  static func name(for name: String, attempt: Int) -> String {
    let marker = attempt == 1 ? " (conflict from Mac)" : " (conflict from Mac \(attempt))"
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name + marker }
    return name[..<dot] + marker + name[dot...]
  }

  private static let maxAttempts = 99

  /// The device's file `entry` is newer than the save: it stays. With `.keepBoth` the Mac's
  /// contents in `mac` go up beside it as a conflict copy; with `.fail` nothing is written.
  static func keepDevice(
    _ entry: ProviderEntry, _ onConflict: ConflictPolicy, mac: URL,
    on route: DomainController.Route
  ) async throws(TransportError) -> AgentResponse {
    switch onConflict {
    case .fail:
      throw .changedOnDevice(entry.item.path)
    case .keepBoth:
      _ = await route.items.created(
        try await ConflictCopy.upload(mac, beside: entry.item.path, route))
      return .keptOnDevice(entry)
    }
  }
}
