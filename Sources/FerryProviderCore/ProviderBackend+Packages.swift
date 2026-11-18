import DeviceKit
import FerryIPC
import FileProvider
import Foundation
import os

private let packageLog = Logger(
  subsystem: "io.github.krisarmstrong.ferry", category: "ProviderBackend")

// MARK: Document packages

extension ProviderBackend {
  /// Sends the local package folder `folder` as one archive with `request`, a `.createPackage`
  /// or `.replacePackage`, and returns the package as the agent made it.
  func sendingPackage(_ folder: URL, as request: AgentRequest) async throws -> ProviderEntry {
    let archive = FileManager.default.temporaryDirectory.appending(
      path: "ferry-package-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: archive) }
    guard FileManager.default.createFile(atPath: archive.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: archive)
    do throws(TransportError) {
      defer { try? writer.close() }
      try PackageArchive.write(tree: folder, to: writer, budget: treeBudget)
    } catch {
      throw ErrorMapping.fileProviderError(error)
    }
    let reader = try FileHandle(forReadingFrom: archive)
    defer { try? reader.close() }
    return try await entry(request, file: reader)
  }

  /// Extracts the archive at `archive` into a new folder in `dir` and returns it, with every
  /// folder and file in it, and the folder itself, carrying `quarantine` as
  /// `com.apple.quarantine`: FileProvider sets an item's attributes on the package itself only.
  static func unpack(_ archive: URL, in dir: URL, quarantine: Data) throws -> URL {
    let folder = dir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let reader = try FileHandle(forReadingFrom: archive)
    defer { try? reader.close() }
    do throws(TransportError) {
      try PackageArchive.extract(from: reader, to: folder, quarantine: quarantine)
    } catch {
      packageLog.error("extracting a fetched package failed: \(error, privacy: .private)")
      try? FileManager.default.removeItem(at: folder)
      throw ErrorMapping.fileProviderError(error)
    }
    return folder
  }
}
