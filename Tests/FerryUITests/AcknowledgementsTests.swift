import Foundation
import Testing

@testable import FerryUI

/// Ferry ships Sparkle (MIT), libmtp and libusb (LGPL-2.1) and fetches Google's adb under the
/// Android SDK License: each is acknowledged in Help, in the README and in the release bundle,
/// and the release check refuses a bundle without them (audit M5, M6).
struct AcknowledgementsTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])

  @Test func helpAcknowledgesEveryComponent() throws {
    let topic = try #require(Self.help.topics.first { $0.id == "acknowledgements" })
    let text = topic.strings.joined(separator: "\n")
    for name in [
      "Sparkle", "MIT", "libmtp", "libusb", "Lesser General Public License",
      "Android SDK License", "source",
    ] {
      #expect(text.contains(name), "Help's Acknowledgements does not name \(name)")
    }
  }

  @Test func theReadmeAcknowledgesSparkle() throws {
    let readme = try String(contentsOf: Self.root.appending(path: "README.md"), encoding: .utf8)
    #expect(readme.contains("[Sparkle](https://github.com/sparkle-project/Sparkle)"))
    #expect(readme.contains("attached to each"))
  }

  /// A fake release bundle with the LGPL texts but no Sparkle licence fails the release check,
  /// and passes its licence section once Sparkle's is there.
  @Test func theReleaseCheckRequiresSparklesLicence() throws {
    let app = URL(filePath: NSTemporaryDirectory())
      .appending(path: "ferry-ack-\(UUID().uuidString)/Ferry.app", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let frameworks = app.appending(path: "Contents/Frameworks")
    let licenses = app.appending(path: "Contents/Resources/Licenses")
    for folder in [frameworks, licenses] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    for lib in ["libmtp.9.dylib", "libusb-1.0.0.dylib"] {
      try Data("x".utf8).write(to: frameworks.appending(path: lib))
    }
    for text in ["libusb-1.0.29-COPYING.txt", "libmtp-1.1.23-COPYING.txt"] {
      try Data("LGPL".utf8).write(to: licenses.appending(path: text))
    }
    let sha = String(repeating: "a", count: 64)
    let readme = """
      libusb 1.0.29
      https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2
      SHA-256: \(sha)

      libmtp 1.1.23
      https://github.com/libmtp/libmtp/releases/download/v1.1.23/libmtp-1.1.23.tar.gz
      SHA-256: \(sha)
      The exact tarballs are attached to each Ferry release on GitHub.
      """
    try Data(readme.utf8).write(to: licenses.appending(path: "README.txt"))

    let without = try Self.check(app)
    #expect(without.contains("Sparkle-LICENSE.txt"), "\(without)")

    try Data("Copyright (c) 2006-2013 Andy Matuschak.".utf8)
      .write(to: licenses.appending(path: "Sparkle-LICENSE.txt"))
    let with = try Self.check(app)
    #expect(with.contains("release build carries"), "\(with)")
  }

  /// scripts/check-release.sh's output; it stops at the first failure.
  private static func check(_ app: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = [root.appending(path: "scripts/check-release.sh").path, app.path, "adhoc"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(bytes: output, encoding: .utf8) ?? ""
  }
}
