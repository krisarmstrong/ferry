import Synchronization

/// What a request's client can say to the agent while it runs, and what the agent tells it.
///
/// - Cancel: the client sends `AgentXPC.cancel(_:)` under the request's identifier when its
///   caller stops waiting (FileProvider cancelled the operation's `Progress`, the user pressed
///   Cancel) or the reply is overdue. The agent also cancels a client's requests when its
///   connection goes away, unless the client is the Finder Sync extension, whose Send and Install
///   must finish after Finder closes its menu.
/// - Started: the agent calls `markStarted()` once the request has its turn at the device (the
///   domain's gate, for requests on a Finder location; at once for the rest), which tells the
///   client over `AgentClientXPC.started(_:)`; the client's reply deadline runs from then, so
///   waiting behind a transfer is never mistaken for a wedged device.
///
/// A request cancelled while it waits for the gate is dropped when it gets it: it touches no
/// device and answers `.cancelled`. Once it runs, only a transfer stops: its progress handler
/// reads the flag and answers "stop", so libmtp or the sync service ends it at its next block and
/// the session cleans up as for any failed write. A flag rather than cancelling the handler's
/// task: that cleanup (the partial file's delete, the temporary APK's `rm`) talks to the device,
/// and in a cancelled task that I/O would itself be cancelled.
public final class RequestCancellation: Sendable {
  private let cancelled = Atomic(false)
  private let started = Atomic(false)
  private let onStart: @Sendable () -> Void

  public init(onStart: @escaping @Sendable () -> Void = {}) {
    self.onStart = onStart
  }

  public var isCancelled: Bool { cancelled.load(ordering: .acquiring) }

  public func cancel() {
    cancelled.store(true, ordering: .releasing)
  }

  /// The request has its turn at the device; the client hears it once.
  public func markStarted() {
    guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
    onStart()
  }

  /// The request the current task is handling; `nil` outside one.
  @TaskLocal public static var current: RequestCancellation?
}

extension AgentRequest {
  /// Whether a client's cancel reaches the request. Every request but a recording: one runs
  /// until Stop or its time limit, even if the app that started it quits.
  public var isCancellable: Bool {
    switch self {
    case .startRecording:
      false
    case .fetch, .replaceContents, .sendFile, .installAPK, .saveRecording, .create, .status,
      .devices, .recheck, .recheckADB, .connectAddress, .pair, .connectWireless, .enableWireless,
      .forgetWireless, .confirmWireless, .ignoreWireless, .screenshot, .stopRecording,
      .discardRecording, .startLogcat, .stopLogcat, .forwards, .addForward, .removeForward,
      .deviceInfo, .shellTarget, .refresh, .eject, .removeAllDomains, .item, .list, .rename,
      .move, .delete, .changes, .workingSet:
      true
    }
  }

  /// Whether the reply may take as long as the work does, so the client sets no deadline on it:
  /// a transfer, which reports its progress; a request answered only when it ends (a recording,
  /// a log stream); one that waits for transfers to finish (an eject, Remove Ferry) or walks
  /// whole folder trees (Refresh, a recursive delete); and a network connect, which tries each
  /// address with adb's own 30 s limit, one after another. The rest are metadata calls, answered
  /// within `AgentClient.replyDeadline` of starting (see `RequestCancellation.markStarted()`) or
  /// taken as an agent that stopped answering.
  public var mayTakeLong: Bool {
    switch self {
    case .fetch, .replaceContents, .sendFile, .installAPK, .saveRecording, .startRecording,
      .startLogcat, .eject, .removeAllDomains, .refresh, .connectAddress, .pair,
      .connectWireless, .enableWireless, .confirmWireless:
      true
    case .create(_, _, _, let isFolder):
      !isFolder
    case .delete(_, _, _, let recursive):
      recursive
    case .status, .devices, .recheck, .recheckADB, .forgetWireless, .ignoreWireless, .screenshot,
      .stopRecording, .discardRecording, .stopLogcat, .forwards, .addForward, .removeForward,
      .deviceInfo, .shellTarget, .item, .list, .rename, .move, .changes, .workingSet:
      false
    }
  }
}
