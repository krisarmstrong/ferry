import Synchronization

/// A client's cancel of one request, as the agent's transfers see it.
///
/// The client sends `AgentXPC.cancel(_:)` under the request's identifier when the caller stops
/// waiting (FileProvider cancelled the operation's `Progress`, the user pressed Cancel) or the
/// reply is overdue, and the agent cancels every request of a client whose connection goes away.
/// The handler runs with the request's cancellation as `current`; a transfer reads it from its
/// progress handler, which then answers "stop", so libmtp or the sync service ends the transfer
/// at its next block and the session cleans up as for any failed write.
///
/// A flag rather than cancelling the handler's task: the cleanup after a stopped transfer (the
/// partial file's delete, the temporary APK's `rm`) talks to the device, and in a cancelled task
/// that I/O would itself be cancelled.
public final class RequestCancellation: Sendable {
  private let cancelled = Atomic(false)

  public init() {}

  public var isCancelled: Bool { cancelled.load(ordering: .acquiring) }

  public func cancel() {
    cancelled.store(true, ordering: .releasing)
  }

  /// The cancellation of the request the current task is handling; `nil` outside one, or for a
  /// request that cannot be cancelled (see `AgentRequest.isCancellable`).
  @TaskLocal public static var current: RequestCancellation?
}

extension AgentRequest {
  /// Whether a client can stop the request once the agent has started it: the transfers, whose
  /// progress handlers read the cancel. A recording runs until Stop or its time limit, even if
  /// the app that started it quits; everything else is answered without moving file contents.
  public var isCancellable: Bool {
    switch self {
    case .fetch, .replaceContents, .sendFile, .installAPK, .saveRecording:
      true
    case .create(_, _, _, let isFolder):
      !isFolder
    case .status, .devices, .recheck, .recheckADB, .connectAddress, .pair, .connectWireless,
      .enableWireless, .forgetWireless, .confirmWireless, .ignoreWireless, .screenshot,
      .startRecording, .stopRecording, .discardRecording, .startLogcat, .stopLogcat, .forwards,
      .addForward, .removeForward, .deviceInfo, .shellTarget, .refresh, .eject,
      .removeAllDomains, .item, .list, .rename, .move, .delete, .changes, .workingSet:
      false
    }
  }

  /// Whether the reply may take as long as the work does, so the client sets no deadline on it:
  /// a transfer, which reports its progress; a request answered only when it ends (a recording,
  /// a log stream); and one that waits for transfers to finish (an eject, Remove Ferry) or walks
  /// whole folder trees (Refresh, a recursive delete). The rest are metadata calls, answered
  /// within `AgentClient.replyDeadline` or taken as an agent that stopped answering.
  public var mayTakeLong: Bool {
    switch self {
    case .fetch, .replaceContents, .sendFile, .installAPK, .saveRecording, .startRecording,
      .startLogcat, .eject, .removeAllDomains, .refresh:
      true
    case .create(_, _, _, let isFolder):
      !isFolder
    case .delete(_, _, _, let recursive):
      recursive
    case .status, .devices, .recheck, .recheckADB, .connectAddress, .pair, .connectWireless,
      .enableWireless, .forgetWireless, .confirmWireless, .ignoreWireless, .screenshot,
      .stopRecording, .discardRecording, .stopLogcat, .forwards, .addForward, .removeForward,
      .deviceInfo, .shellTarget, .item, .list, .rename, .move, .changes, .workingSet:
      false
    }
  }
}
