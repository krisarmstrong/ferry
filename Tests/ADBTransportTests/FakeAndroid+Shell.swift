import Foundation

/// The device's `sh` and the toybox 0.7.4 commands a session runs, from their sources
/// (`toys/posix/{cp,rm,mkdir,df}.c`, `lib/lib.c`). Messages are toybox's `perror_msg` forms
/// with bionic's `strerror` text; the read-only ones (`df`, `stat`) match a LinkRunner's output.
extension FakeAndroid {
  struct ShellResult {
    var status: Int32 = 0
    var stdout = ""
    var stderr = ""

    mutating func fail(_ line: String) {
      stderr += line + "\n"
      status = 1
    }
  }

  func shell(_ command: String) -> ShellResult {
    guard let words = Self.words(command), let program = words.first else {
      return ShellResult(status: 2, stderr: "sh: syntax error: \(command)\n")
    }
    state.withLock { $0.commands.append(words) }
    let hooks = state.withLock { state in
      let due = state.beforeShell.filter { $0.program == program }
      state.beforeShell.removeAll { $0.program == program }
      return due
    }
    for hook in hooks { hook.action(self) }
    if let failure = state.withLock({ state -> ShellFailure? in
      guard let index = state.shellFailures.firstIndex(where: { $0.program == program }) else {
        return nil
      }
      return state.shellFailures.remove(at: index)
    }) {
      return ShellResult(status: failure.status, stderr: failure.stderr + "\n")
    }
    let allowed: [String: Set<Character>] = [
      "mv": ["f", "i", "v", "n"], "rm": ["f", "i", "R", "r"], "mkdir": ["v", "p"],
      "df": ["H", "P", "k", "h", "a"],
    ]
    guard let flags = allowed[program] else {
      return ShellResult(status: 127, stderr: "/system/bin/sh: \(program): not found\n")
    }
    var options: Set<Character> = []
    var operands: [String] = []
    var endOfOptions = false
    // toybox reads options anywhere on the line until `--`.
    for word in words.dropFirst() {
      if endOfOptions || word == "-" || !word.hasPrefix("-") {
        operands.append(word)
      } else if word == "--" {
        endOfOptions = true
      } else {
        for flag in word.dropFirst() {
          guard flags.contains(flag) else {
            return ShellResult(status: 1, stderr: "\(program): Unknown option '\(flag)'\n")
          }
          options.insert(flag)
        }
      }
    }
    return state.withLock { [operands, options] state in
      switch program {
      case "mv": Self.mv(operands, noClobber: options.contains("n"), in: &state)
      case "rm": Self.rm(operands, recursive: !options.isDisjoint(with: ["r", "R"]), in: &state)
      case "mkdir": Self.mkdir(operands, in: &state)
      default: Self.df(operands, in: state)
      }
    }
  }

  /// Splits a command line the way `sh` does for the subset a session may send: plain words,
  /// single quotes, and a backslash quoting the next character. Anything else the shell would
  /// interpret (`$`, `;`, `"`, a bare newline, a glob) is refused, so a name that leaks out of
  /// its quoting fails the test instead of passing by luck.
  static func words(_ command: String) -> [String]? {
    let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./,:=+@%"))
    var words: [String] = []
    var current: String.UnicodeScalarView?
    var scalars = command.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case " ":
        if let word = current { words.append(String(word)) }
        current = nil
      case "'":
        var word = current ?? String.UnicodeScalarView()
        var closed = false
        while let quoted = scalars.next() {
          if quoted == "'" {
            closed = true
            break
          }
          word.append(quoted)
        }
        guard closed else { return nil }
        current = word
      case "\\":
        guard let escaped = scalars.next(), escaped != "\n" else { return nil }
        current = (current ?? String.UnicodeScalarView())
        current?.append(escaped)
      default:
        guard plain.contains(scalar), scalar.isASCII else { return nil }
        current = (current ?? String.UnicodeScalarView())
        current?.append(scalar)
      }
    }
    if let word = current { words.append(String(word)) }
    return words
  }

  // MARK: Commands

  static let noEntry = "No such file or directory"

  /// `mv [-n] SOURCE DEST`, as `cp_main` runs it: an existing folder at DEST receives SOURCE; with
  /// `-n` an existing target is left alone and the exit status is still 0; a failed `rename` is
  /// `bad 'SOURCE'` whichever side was missing.
  private static func mv(_ operands: [String], noClobber: Bool, in state: inout State)
    -> ShellResult
  {
    var result = ShellResult()
    guard operands.count == 2 else {
      result.fail("mv: Need 2 arguments")
      return result
    }
    let source = FakeAndroid.bytes(operands[0])
    var destination = FakeAndroid.bytes(operands[1])
    if case .folder = state.node(at: destination) {
      destination += [UInt8(ascii: "/")] + FakeAndroid.name(source)
    }
    if noClobber, state.node(at: destination) != nil { return result }
    if let failure = rename(source, to: destination, in: &state) {
      result.fail("mv: bad '\(operands[0])': \(failure)")
    }
    return result
  }

  /// `rename(2)`; the `strerror` text of its failure, if any.
  private static func rename(_ source: Path, to destination: Path, in state: inout State)
    -> String?
  {
    guard let from = state.resolve(source),
      let parent = state.resolve(FakeAndroid.parent(destination))
    else { return noEntry }
    guard case .folder = state.nodes[parent] else { return "Not a directory" }
    let target = parent + [UInt8(ascii: "/")] + FakeAndroid.name(destination)
    if let existing = state.resolve(destination) {
      // The same file under another case: the kernel does nothing and reports success.
      if existing == from { return nil }
      switch (state.nodes[from], state.nodes[existing]) {
      case (.folder, .folder):
        guard state.children(of: existing).isEmpty else { return "Directory not empty" }
      case (.folder, _): return "Not a directory"
      case (_, .folder): return "Is a directory"
      default: break
      }
      state.remove(existing)
    }
    guard !isSame(target, orInside: from) else { return "Invalid argument" }
    state.relocate(from, to: target)
    return nil
  }

  private static func rm(_ operands: [String], recursive: Bool, in state: inout State)
    -> ShellResult
  {
    var result = ShellResult()
    for operand in operands {
      guard let path = state.resolve(FakeAndroid.bytes(operand)) else {
        result.fail("rm: \(operand): \(noEntry)")
        continue
      }
      if case .folder = state.nodes[path], !recursive {
        result.fail("rm: \(operand): Is a directory")
        continue
      }
      state.remove(path)
    }
    return result
  }

  private static func mkdir(_ operands: [String], in state: inout State) -> ShellResult {
    var result = ShellResult()
    for operand in operands {
      let path = FakeAndroid.bytes(operand)
      if state.node(at: path) != nil {
        result.fail("mkdir: '\(operand)': File exists")
        continue
      }
      guard let parent = state.resolve(FakeAndroid.parent(path)) else {
        result.fail("mkdir: '\(operand)': \(noEntry)")
        continue
      }
      guard case .folder = state.nodes[parent] else {
        result.fail("mkdir: '\(operand)': Not a directory")
        continue
      }
      state.nodes[parent + [UInt8(ascii: "/")] + FakeAndroid.name(path)] = .folder(
        mtime: state.tick())
    }
    return result
  }

  /// `df -k PATH`, column widths as the LinkRunner prints them, a column never touching the
  /// next. toybox reports a missing path twice.
  private static func df(_ operands: [String], in state: State) -> ShellResult {
    var result = ShellResult(stdout: "Filesystem     1K-blocks   Used Available Use% Mounted on\n")
    for operand in operands {
      let path = FakeAndroid.bytes(operand)
      guard state.node(at: path) != nil,
        let mount = state.mounts.filter({ isSame(path, orInside: $0.mountPoint) })
          .max(by: { $0.mountPoint.count < $1.mountPoint.count })
      else {
        result.fail("df: '\(operand)': \(noEntry)")
        result.fail("df: '\(operand)': \(noEntry)")
        continue
      }
      let available = mount.total - mount.used
      let percent = (mount.used * 100 + mount.total - 1) / max(mount.total, 1)
      result.stdout +=
        mount.filesystem.padding(toLength: 15, withPad: " ", startingAt: 0)
        + pad(mount.total, 9) + pad(mount.used, 7) + pad(available, 10) + pad(percent, 4) + "% "
        + FakeAndroid.text(mount.mountPoint) + "\n"
    }
    return result
  }

  private static func pad(_ value: UInt64, _ width: Int) -> String {
    let text = String(value)
    return String(repeating: " ", count: max(width - text.count, 1)) + text
  }
}
