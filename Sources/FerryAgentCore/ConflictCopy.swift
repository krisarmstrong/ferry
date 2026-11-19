import DeviceKit
import FerryIPC
import Foundation

/// The copy the agent keeps of the Mac's contents when they were made from a version of the file
/// the device no longer has: the device's file stays, and the Mac's goes up beside it.
enum ConflictCopy {
  /// Uploads `scratch` beside `path` under the first free conflict name.
  static func upload(
    _ scratch: URL, beside path: RemotePath, _ route: DomainController.Route,
    progress: @escaping ProgressHandler = AgentService.ignoreProgress
  ) async throws(TransportError) -> RemoteItem {
    let (parent, name) = (path.parent ?? .root, path.name ?? "")
    for attempt in 1...maxAttempts {
      let copy = try parent.appending(self.name(for: name, attempt: attempt))
      do {
        return try await route.writer.write(
          from: scratch, to: copy, in: route.storage, replacing: false, progress: progress)
      } catch .alreadyExists where attempt < maxAttempts {
        continue
      }
    }
    throw .alreadyExists(path)
  }

  /// `report (conflict from Mac).txt`, then `report (conflict from Mac 2).txt` and so on. The
  /// marker goes before the extension, so the copy opens in the same app. An extension is a
  /// short tail (at most 16 bytes, no space) after a dot that neither starts nor ends the name,
  /// so in `Notes 2026.11.17 meeting` the marker goes at the end. A name a device cannot store
  /// (see `RemotePath.fitsOnDevice`) loses characters from the end of its base, never the marker
  /// or the extension (a single character too long loses its combining marks instead), and the
  /// copy's name never starts with a space or has one before the marker. Spaces are compared as
  /// Unicode scalars, so a space carrying a combining mark counts as one.
  static func name(for name: String, attempt: Int) -> String {
    let marker = attempt == 1 ? " (conflict from Mac)" : " (conflict from Mac \(attempt))"
    let dot = name.lastIndex(of: ".").flatMap { dot -> String.Index? in
      let tail = name[dot...]
      let isExtension =
        dot != name.startIndex && tail.count > 1 && tail.utf8.count <= 17
        && !tail.unicodeScalars.contains(" ")
      return isExtension ? dot : nil
    }
    var base = String(name[..<(dot ?? name.endIndex)])
    while base.unicodeScalars.first == " " { base.removeFirst() }
    let tail = marker + (dot.map { String(name[$0...]) } ?? "")
    while !RemotePath.fitsOnDevice(base + tail), !base.isEmpty {
      if base.count == 1 { base.unicodeScalars.removeLast() } else { base.removeLast() }
    }
    while base.unicodeScalars.last == " " { base.unicodeScalars.removeLast() }
    return base.isEmpty ? String(tail.dropFirst()) : base + tail
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
