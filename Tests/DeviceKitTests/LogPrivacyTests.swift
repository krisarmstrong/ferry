import Foundation
import Testing

/// No log line may make device or user data public (audit M1, L4). Errors carry serials, device
/// paths, network addresses and the Mac's home folder, so an error, a path or an address is
/// logged `.private`.
///
/// Two rules, both default-deny, over `Sources` and `Apps`:
/// - every interpolation in a log message says its privacy, since OSLog shows a number with no
///   `privacy:` in the clear: a port, a PID or a device's numeric ID would leak unseen;
/// - every public one is listed below by its file and the line the interpolation starts on, as
///   reviewed data that is safe in a sysdiagnose. A second public interpolation on another line,
///   one wrapped over lines, or a spelling such as `privacy:.public` or `%{public}` is caught.
struct LogPrivacyTests {
  private static let root = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// `Tests/LogPrivacyAllowList.txt`: each reviewed public interpolation as "file: line", the
  /// file relative to the package and the source line trimmed; `#` starts a comment.
  static func allowed() throws -> Set<String> {
    let text = try String(
      contentsOf: root.appending(path: "Tests/LogPrivacyAllowList.txt"), encoding: .utf8)
    return Set(
      text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") })
  }

  /// Every Swift file under `Sources` and `Apps`, by its path relative to the package.
  static func sources() throws -> [(path: String, text: String)] {
    var found: [(String, String)] = []
    for folder in ["Sources", "Apps"] {
      let base = root.appending(path: folder, directoryHint: .isDirectory)
      guard
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
      else { continue }
      for case let file as URL in walker where file.pathExtension == "swift" {
        found.append(
          (
            String(file.path.dropFirst(root.path.count + 1)),
            try String(contentsOf: file, encoding: .utf8)
          ))
      }
    }
    return found
  }

  /// The trimmed line on which each public interpolation in `text` starts, however it is
  /// spelled or wrapped; a `%{public}` format names its own line.
  static func publicLines(in text: String) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    func line(at index: String.Index) -> String {
      let number = text[..<index].count { $0 == "\n" }
      return lines[number].trimmingCharacters(in: .whitespaces)
    }
    var found: [String] = []
    for match in text.matches(of: /privacy:\s*\.public\b/) {
      found.append(line(at: opening(before: match.range.lowerBound, in: text)))
    }
    for match in text.matches(of: /%\{public\}/) {
      found.append(line(at: match.range.lowerBound))
    }
    return found
  }

  /// The interpolations in log messages that do not say their privacy.
  static func unannotated(in text: String) -> [String] {
    var found: [String] = []
    let calls = /\b(?:log|logger)\.(?:log|info|debug|error|fault|notice|warning|trace|critical)\(/
    for call in text.matches(of: calls) {
      let body = text[call.range.upperBound...].prefix(while: { _ in true })
      let end = closing(from: call.range.upperBound, in: text)
      var search = body.startIndex
      while let start = text.range(of: "\\(", range: search..<end)?.upperBound {
        let finish = closing(from: start, in: text)
        let inner = text[start..<text.index(before: finish)]
        if !inner.contains("privacy:") { found.append(String(inner)) }
        search = finish
      }
    }
    return found
  }

  /// Where the `(` that is open at `index` is.
  private static func opening(before index: String.Index, in text: String) -> String.Index {
    var depth = 0
    var position = index
    while position > text.startIndex {
      position = text.index(before: position)
      if text[position] == ")" { depth += 1 }
      if text[position] == "(" {
        if depth == 0 { return position }
        depth -= 1
      }
    }
    return position
  }

  /// Just past the `)` that closes the `(` open before `index`.
  private static func closing(from index: String.Index, in text: String) -> String.Index {
    var depth = 1
    var position = index
    while position < text.endIndex, depth > 0 {
      if text[position] == "(" { depth += 1 }
      if text[position] == ")" { depth -= 1 }
      position = text.index(after: position)
    }
    return position
  }

  @Test func everyPublicInterpolationIsReviewed() throws {
    var found: [String] = []
    for source in try Self.sources() {
      found += Self.publicLines(in: source.text).map { "\(source.path): \($0)" }
    }
    #expect(!found.isEmpty, "the scan found no public interpolations: is the root right?")
    let allowed = try Self.allowed()
    for entry in found {
      #expect(allowed.contains(entry), "not reviewed as public: \(entry)")
    }
    for entry in allowed {
      #expect(found.contains(entry), "allowed but no longer in the source: \(entry)")
    }
  }

  @Test func everyLoggedValueSaysItsPrivacy() throws {
    for source in try Self.sources() {
      for expression in Self.unannotated(in: source.text) {
        Issue.record("no privacy: \(source.path): \\(\(expression))")
      }
    }
  }

  /// The scanner finds public interpolations however they are written.
  @Test func theScannerFindsEachSpelling() {
    let source = #"""
      log.error("a \(error, privacy: .public)")
      log.error("b \(error,
          privacy:.public)")
      log.info("\(count, privacy: .public, attributes: "x") \(path, privacy: .private)")
      os_log("%{public}@", name)
      """#
    #expect(Self.publicLines(in: source).count == 4)
    #expect(Self.publicLines(in: source)[1] == #"log.error("b \(error,"#)
  }

  @Test func theScannerFindsABareValue() {
    let source = #"log.info("port \(port) of \(device, privacy: .private)")"#
    #expect(Self.unannotated(in: source) == ["port"])
  }
}
