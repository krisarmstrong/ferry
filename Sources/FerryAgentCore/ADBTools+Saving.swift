import ADBTransport
import DeviceKit
import FerryIPC
import Foundation

extension ADBTools {
  // MARK: Saving

  typealias Writer = (FileHandle) async throws(SaveError) -> Void

  enum SaveError: Error {
    case tool(ToolFailure)
    case transport(TransportError)
  }

  /// Writes a capture with `write` into the screenshot folder (or the Desktop, if the folder will
  /// not take it), checks it starts as `kind` must, and names it. Nothing is left on failure.
  func save(
    _ kind: CaptureFiles.Kind, of target: Target, at date: Date, failure: ToolFailure,
    _ write: (FileHandle) async throws(SaveError) -> Void
  ) async throws(TransportError) -> Outcome {
    let preferred = folder()
    let folders =
      preferred.standardizedFileURL == desktop.standardizedFileURL
      ? [preferred] : [preferred, desktop]
    var opened: (url: URL, handle: FileHandle)?
    for folder in folders where opened == nil {
      opened = CaptureFiles.temporary(in: folder)
    }
    guard let (temporary, handle) = opened else { return .failed(.cannotSave) }
    do throws(SaveError) {
      try await write(handle)
      do {
        try handle.synchronize()
        try handle.close()
      } catch {
        throw .transport(.io("cannot write the file: \(error.localizedDescription)"))
      }
      guard Self.looksLike(kind, at: temporary) else { throw .tool(failure) }
      return .saved(
        try Self.placing(
          temporary, base: CaptureFiles.baseName(kind, model: target.model, at: date),
          fileExtension: kind.fileExtension))
    } catch {
      try? handle.close()
      FileTransfer.remove(temporary)
      switch error {
      case .tool(let tool): return .failed(tool)
      case .transport(let transport): throw transport
      }
    }
  }

  static func placing(_ url: URL, base: String, fileExtension: String)
    throws(SaveError) -> URL
  {
    do throws(TransportError) {
      return try CaptureFiles.place(url, base: base, fileExtension: fileExtension)
    } catch {
      throw .transport(error)
    }
  }

  /// A PNG starts with its signature; an MP4 with a box whose type is `ftyp`.
  static func looksLike(_ kind: CaptureFiles.Kind, at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 12)) ?? Data()
    switch kind {
    case .screenshot: return head.starts(with: pngMagic)
    case .recording: return head.count == 12 && head.dropFirst(4).prefix(4) == Data("ftyp".utf8)
    }
  }

  static func size(of descriptor: Int32) throws(TransportError) -> UInt64 {
    try FileTransfer.requireRegular(descriptor)
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw .io("cannot inspect the app") }
    return UInt64(clamping: info.st_size)
  }

  /// A device or server that went away is a disconnected device, as for files; adb's other
  /// failures carry its words.
  static func transportError(_ error: ADBError) -> TransportError {
    switch error {
    case .deviceGone, .connectionClosed, .serverUnavailable, .adbNotInstalled:
      .deviceDisconnected
    case .cancelled:
      .cancelled
    case .failed(let message) where message.contains("offline") || message.contains("unauthorized"):
      .deviceDisconnected
    case .failed(let message), .protocolViolation(let message), .invalidArgument(let message):
      .io(message)
    }
  }
}
