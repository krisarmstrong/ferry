import Foundation
import Testing

/// No log line may make device or user data public (audit M1, L4). Errors carry serials, device
/// paths, network addresses and the Mac's home folder, so an error, a path or an address is
/// logged `.private`. The check is default-deny: every `privacy: .public` interpolation in
/// `Sources` and `Apps` must be listed below, by file and expression, as data that is safe to
/// show in a sysdiagnose. A new public interpolation fails here until it is reviewed and listed.
struct LogPrivacyTests {
  /// File, relative to the package, and the interpolated expression, as written.
  static let allowed: Set<String> = [
    // Counts, durations and kernel return codes.
    "Sources/FerryAgentCore/DomainController+Visibility.swift: systemHidden.count",
    "Sources/FerryAgentCore/TransferBoard.swift: completed",
    "Sources/FerryAgentCore/TransferBoard.swift: total",
    "Sources/FerryAgentCore/USBWatcher.swift: retryInterval",
    "Sources/FerryAgentCore/USBWatcher.swift: subscription.type",
    "Sources/FerryAgentCore/USBWatcher.swift: result",
    // A transport's name ("MTP", "ADB").
    "Sources/FerryAgentCore/DeviceHub+Swap.swift: target.name",
    "Sources/FerryAgentCore/DeviceHub+Swap.swift: via",
    "Sources/FerryAgentCore/DeviceHub.swift: opened.rawValue",
    "Sources/FerryAgentCore/CompositeTransport.swift: name",
    // An MTP storage's numeric ID, which the device assigns per session.
    "Sources/MTPTransport/MTPDevice.swift: id",
    // The agent's state and the menu's summary: device kinds and connection methods, never
    // names, serials or addresses.
    "Sources/FerryUI/SystemServices.swift: Self.describe(agent.status)",
    "Sources/FerryUI/AppModel.swift: states",
    "Sources/FerryUI/AppModel.swift: report.provider.rawValue",
    "Sources/FerryUI/AppModel.swift: adb",
  ]

  private static let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// Every `privacy: .public` interpolation under `folder`, as "file: expression".
  static func publicInterpolations(in folder: String) throws -> [String] {
    let base = root.appending(path: folder, directoryHint: .isDirectory)
    guard
      let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    else { return [] }
    var found: [String] = []
    for case let file as URL in walker where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      let relative = String(file.path.dropFirst(root.path.count + 1))
      found += expressions(in: text).map { "\(relative): \($0)" }
    }
    return found
  }

  /// The expression before each `, privacy: .public)`, back to the `\(` that opens it.
  static func expressions(in text: String) -> [String] {
    let marker = ", privacy: .public)"
    var expressions: [String] = []
    var searchEnd = text.endIndex
    while true {
      let before = text.startIndex..<searchEnd
      guard let range = text.range(of: marker, options: .backwards, range: before) else { break }
      searchEnd = range.lowerBound
      var depth = 0
      var index = range.lowerBound
      while index > text.startIndex {
        index = text.index(before: index)
        let character = text[index]
        if character == ")" { depth += 1 }
        if character == "(" {
          if depth == 0 { break }
          depth -= 1
        }
      }
      let expression = text[text.index(after: index)..<range.lowerBound]
      expressions.append(expression.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
    return expressions
  }

  @Test func everyPublicInterpolationIsReviewed() throws {
    let found = try Self.publicInterpolations(in: "Sources") + Self.publicInterpolations(in: "Apps")
    #expect(!found.isEmpty, "the scan found no public interpolations: is the root right?")
    for entry in found {
      #expect(Self.allowed.contains(entry), "not reviewed as public: \(entry)")
    }
  }

  /// The scanner finds the expression whatever it holds, so an error described in place is
  /// caught as well as a bare one.
  @Test func theScannerFindsEachExpression() {
    let source = #"""
      log.error("a \(error, privacy: .public) b \(String(describing: error), privacy: .public)")
      log.info("\(count, privacy: .public) \(path, privacy: .private)")
      """#
    #expect(
      Self.expressions(in: source).sorted()
        == ["String(describing: error)", "count", "error"])
  }
}
