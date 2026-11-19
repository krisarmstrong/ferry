import Foundation

@testable import ADBTransport

/// The device side of Ferry's tools: `screencap` over `exec:`, `pm install`, and `screenrecord`
/// started through `sh -c` and stopped with `kill -2`, as Android 8 runs them.
extension FakeAndroid {
  struct Tools {
    /// Every service the client started, in order.
    var services: [String] = []
    /// What `screencap -p` writes.
    var screencap =
      Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 300_000)
    /// What `pm install` prints, and its exit status.
    var pmResult = ShellResult(stdout: "Success\n")
    /// The APK contents each `pm install` found at its path.
    var installed: [Data] = []
    /// The pid the recording script prints, unless `pidLine` replaces the whole line.
    var pid = 4242
    var pidLine: String?
    /// The recording running now, if any.
    var recording: Recording?
    /// Whether `screenrecord` stops by itself (its time limit) without a signal.
    var recordingEndsOnItsOwn = false
    /// What `screenrecord` leaves at its path when it finishes.
    var recordingBytes =
      Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8) + Data(repeating: 1, count: 2_000)
    /// What `logcat -v threadtime` sends, chunk by chunk, then whether it ends (the buffer was
    /// dumped) or stays open following the log until the client closes.
    var logcat: [Data] = []
    var logcatEnds = false
    /// What `dumpsys battery` prints; `nil` is a device with no battery service.
    var battery: String?
    /// The adb server's forwards, for every device it has, as `list-forward` lists them.
    var forwards: [Forward] = []
    /// Local ports the server cannot bind.
    var takenPorts: Set<UInt16> = []
  }

  struct Forward: Equatable {
    var serial: String
    var local: String
    var remote: String
  }

  struct Recording {
    let pid: Int
    var interrupted = false
  }

  var services: [String] { state.withLock { $0.tools.services } }
  var installed: [Data] { state.withLock { $0.tools.installed } }

  /// The node at an absolute path on the device.
  func node(absolute path: String) -> Node? {
    state.withLock { $0.node(at: Self.bytes(path)) }
  }

  func setTools(_ change: @Sendable (inout Tools) -> Void) {
    state.withLock { change(&$0.tools) }
  }

  /// `exec:` runs the command with no pty and no framing: its stdout, then the connection closes.
  func exec(_ command: String, _ peer: Peer) async throws {
    guard let words = Self.words(command) else { throw ScriptError.unexpected(command) }
    state.withLock { $0.commands.append(words) }
    if words == ["logcat", "-v", "threadtime"] {
      try await logcat(peer)
      return
    }
    guard words == ["screencap", "-p"] else { throw ScriptError.unexpected(command) }
    if state.withLock({ $0.hangingPrograms.contains("screencap") }) {
      _ = try? await peer.stream.read(exactly: 1)
      return
    }
    try await peer.raw(state.withLock { $0.tools.screencap })
    await peer.finish()
  }

  /// Sends the scripted log, then follows it (nothing more arrives) or ends it.
  private func logcat(_ peer: Peer) async throws {
    let (chunks, ends) = state.withLock { ($0.tools.logcat, $0.tools.logcatEnds) }
    for chunk in chunks { try await peer.raw(chunk) }
    if ends {
      await peer.finish()
    } else {
      _ = try? await peer.stream.read(exactly: 1)
    }
  }

  /// The adb server's forward requests, as `adb.cpp`'s `handle_forward_request` answers them on
  /// the host (`SendOkay`, then the list, for `list-forward`; two `OKAY`s for a `forward` or
  /// `killforward` that worked; one `FAIL` frame, with no `OKAY` first, for one that did not).
  /// False for any other request.
  func forwardRequest(_ request: String, serial: String, _ peer: Peer) async throws -> Bool {
    let prefix = "host-serial:\(serial):"
    guard request.hasPrefix(prefix) else { return false }
    let service = String(request.dropFirst(prefix.count))
    if service == "list-forward" {
      let lines = state.withLock { state in
        state.tools.forwards.map { "\($0.serial) \($0.local) \($0.remote)\n" }.joined()
      }
      try await peer.answer(lines)
      return true
    }
    if service.hasPrefix("forward:") {
      let pieces = service.dropFirst("forward:".count).split(
        separator: ";", omittingEmptySubsequences: false)
      guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty, pieces[1].first != "*" else {
        try await peer.fail("bad forward: \(service.dropFirst("forward:".count))")
        return true
      }
      let (local, remote) = (String(pieces[0]), String(pieces[1]))
      let taken = state.withLock { state in
        local.hasPrefix("tcp:")
          && UInt16(local.dropFirst(4)).map(state.tools.takenPorts.contains) == true
      }
      guard !taken else {
        try await peer.fail("cannot bind listener: Address already in use")
        return true
      }
      state.withLock { state in
        state.tools.forwards.removeAll { $0.local == local }
        state.tools.forwards.append(Forward(serial: serial, local: local, remote: remote))
      }
      try await peer.okay()
      try await peer.okay()
      return true
    }
    if service.hasPrefix("killforward:") {
      let local = String(service.dropFirst("killforward:".count))
      let removed = state.withLock { state in
        let before = state.tools.forwards.count
        state.tools.forwards.removeAll { $0.local == local && $0.serial == serial }
        return state.tools.forwards.count != before
      }
      guard removed else {
        try await peer.fail("listener '\(local)' not found")
        return true
      }
      try await peer.okay()
      try await peer.okay()
      return true
    }
    return false
  }

  /// The legacy `shell:` service, for a device without `shell_v2`, wrapped as `ADBShell` wraps a
  /// command: `( <command>\n); printf '\n%s %d\n' '<token>' $?`.
  func legacyShell(_ wrapped: String, _ peer: Peer) async throws {
    let pattern = /^\( (?<command>.*)\n\); printf '\\n%s %d\\n' '(?<token>ferry-[^']+)' \$\?$/
      .dotMatchesNewlines()
    guard let match = wrapped.wholeMatch(of: pattern) else { throw ScriptError.unexpected(wrapped) }
    let command = String(match.command)
    let token = String(match.token)
    if Self.words(command)?.first == "sh" {
      try await record(command, peer, legacyToken: token)
      return
    }
    // stderr is merged into stdout without shell_v2.
    let result = shell(command)
    try await peer.raw(Data((result.stdout + result.stderr).utf8))
    try await exitShell(UInt8(result.status), peer, legacyToken: token)
  }

  /// `sh -c 'echo $$; exec screenrecord --time-limit 180 "$1"' sh PATH`: prints the pid, records
  /// until `kill -2` of that pid (or its own time limit), then leaves the file at PATH and exits 0.
  func record(_ command: String, _ peer: Peer, legacyToken: String?) async throws {
    guard let words = Self.words(command) else { throw ScriptError.unexpected(command) }
    state.withLock { $0.commands.append(words) }
    guard words.count == 5, words[1] == "-c", words[2] == ADBDeviceTools.recordScript,
      words[3] == "sh"
    else { throw ScriptError.unexpected(command) }
    let path = words[4]
    let (pid, line) = state.withLock { state in
      (state.tools.pid, state.tools.pidLine ?? "\(state.tools.pid)\n")
    }
    try await emit(Data(line.utf8), peer, legacy: legacyToken != nil)
    guard line == "\(pid)\n" else {
      // The script failed before screenrecord ran.
      try await exitShell(1, peer, legacyToken: legacyToken)
      return
    }
    state.withLock { $0.tools.recording = Recording(pid: pid) }
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
      let (gone, done) = state.withLock { state in
        (
          state.gone,
          state.tools.recording?.interrupted == true || state.tools.recordingEndsOnItsOwn
        )
      }
      if gone { return }
      if done { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    state.withLock { state in
      if let target = state.create(Self.bytes(path)) {
        state.nodes[target] = .file(state.tools.recordingBytes, mtime: state.tick())
      }
      state.tools.recording = nil
    }
    try await exitShell(0, peer, legacyToken: legacyToken)
  }

  private func emit(_ data: Data, _ peer: Peer, legacy: Bool) async throws {
    try await peer.raw(legacy ? data : Peer.shellPacket(1, data))
  }

  private func exitShell(_ status: UInt8, _ peer: Peer, legacyToken: String?) async throws {
    if let legacyToken {
      try await peer.raw(Data("\n\(legacyToken) \(status)\n".utf8))
      await peer.finish()
    } else {
      try await peer.raw(Peer.shellPacket(3, Data([status])))
    }
  }

  // MARK: Commands

  /// `pm install -r PATH`: what is at PATH is the app pm installs.
  static func pm(_ operands: [String], in state: inout State) -> ShellResult {
    guard operands.count == 2, operands[0] == "install" else {
      return ShellResult(status: 1, stderr: "pm: unsupported in the fake\n")
    }
    guard case .file(let data, _) = state.node(at: bytes(operands[1])) else {
      return ShellResult(
        status: 1, stdout: "Failure [INSTALL_FAILED_INVALID_URI: no file at that path]\n")
    }
    state.tools.installed.append(data)
    return state.tools.pmResult
  }

  /// `dumpsys battery`, or what a device without the service says.
  static func dumpsys(_ operands: [String], in state: State) -> ShellResult {
    guard operands == ["battery"], let battery = state.tools.battery else {
      return ShellResult(status: 20, stderr: "Can't find service: \(operands.first ?? "")\n")
    }
    return ShellResult(stdout: battery)
  }

  /// `kill -2 PID`: interrupts the recording if it is that process.
  static func kill(_ operands: [String], in state: inout State) -> ShellResult {
    guard operands.count == 1, let recording = state.tools.recording,
      operands[0] == String(recording.pid)
    else {
      return ShellResult(status: 1, stderr: "kill: \(operands.first ?? ""): No such process\n")
    }
    state.tools.recording?.interrupted = true
    return ShellResult()
  }
}
