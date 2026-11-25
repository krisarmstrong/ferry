import Foundation

/// A String Catalog compiled the way Xcode compiles it for the app, for tests that check what a
/// translation says once built: plural forms, a language's lookups.
///
/// `swift test` cannot be trusted for this. SwiftPM's native build system copies a `.xcstrings`
/// into the module's bundle as it is, with no `.lproj` (the Swift 6.3 toolchain CI runs), while
/// Swift Build compiles it (6.4's default). Xcode's own `xcstringstool` compiles it here, the same
/// on both; `make check-app` checks the app's bundles.
///
/// Each catalog is compiled once per test process, and the tool runs on a dispatch thread: a
/// blocked thread of the shared pool would hold up the timing-sensitive tests running beside it.
public enum CompiledCatalog {
  public enum Failure: Error, CustomStringConvertible {
    case compileFailed(String)
    case noLanguage(String)

    public var description: String {
      switch self {
      case .compileFailed(let output): "xcstringstool failed: \(output)"
      case .noLanguage(let language): "the compiled catalog has no \(language).lproj"
      }
    }
  }

  /// The strings of the catalog at `catalog` in `language`, as a bundle to look them up in.
  public static func strings(_ catalog: URL, language: String) async throws -> Bundle {
    let output = try await Compiled.shared.folder(for: catalog)
    guard let bundle = Bundle(path: output.appending(path: "\(language).lproj").path) else {
      throw Failure.noLanguage(language)
    }
    return bundle
  }

  private actor Compiled {
    static let shared = Compiled()
    private var folders: [URL: Task<URL, any Error>] = [:]

    func folder(for catalog: URL) async throws -> URL {
      if let task = folders[catalog] { return try await task.value }
      let task = Task { try await CompiledCatalog.compile(catalog) }
      folders[catalog] = task
      return try await task.value
    }
  }

  private static func compile(_ catalog: URL) async throws -> URL {
    let output = try TestScratch.folder("catalog")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = [
      "xcstringstool", "compile", catalog.path, "--output-directory", output.path,
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let said = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do {
          try process.run()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(returning: data)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    guard process.terminationStatus == 0 else {
      throw Failure.compileFailed(String(bytes: said, encoding: .utf8) ?? "")
    }
    return output
  }
}
