import Foundation

/// Starting the agent at launch, and restarting one launchd cannot start.
extension AppModel {
  /// Starts the agent, reads its status, then whether Ferry opens at login, and updates the adb
  /// Ferry fetched if this release pins a newer one. The system calls run off the main actor (see
  /// `SystemServices`), so the app opens without waiting on them.
  public func launch() async {
    restartedBuild = await startAgent()
    await services.registerExtensions()
    await refresh()
    loginItem = await services.loginItemStatus()
    considerPlatformToolsUpdate()
  }

  /// Registers the agent, or restarts it when the agent in the bundle is not the one last
  /// started: after an update the old agent keeps running until it stops, and would serve the
  /// new app and extensions its old code. Without the agent's identity it only registers.
  /// Returns the build restarted, which is recorded only once that agent answers: `register()`
  /// succeeds even when launchd then fails to spawn it, and a build recorded then would leave
  /// every later launch only registering the stuck job.
  private func startAgent() async -> String? {
    guard let build = services.agentBuild(), build != services.startedAgentBuild() else {
      await services.registerAgent()
      return nil
    }
    return await services.restartAgent() ? build : nil
  }

  /// launchd can keep a job it can no longer spawn: after a build signed by another identity is
  /// installed it reports `spawn failed` (`OS_REASON_CODESIGNING`, `EX_CONFIG`) and never starts
  /// the agent, while `SMAppService` still says it is enabled, until the job is removed. An agent
  /// the app cannot reach while macOS has it enabled is therefore restarted (unregistered, which
  /// removes the job, and registered again), once per outage: a restart cuts off every transfer.
  /// Then the app asks for its status a bounded number of times. A status the menu cancelled by
  /// closing says nothing about the agent, and one lost because launchd relaunched the agent
  /// mid-call is answered when asked again, so neither restarts it.
  func recoverAgent() async {
    guard !Task.isCancelled, !recoveryAttempted else { return }
    recoveryAttempted = true
    guard await services.agentIsEnabled() else {
      // Off or awaiting approval is the user's choice; look again at the next failure.
      recoveryAttempted = false
      return
    }
    guard (try? await sleep(Self.recoveryPause)) != nil else {
      recoveryAttempted = false
      return
    }
    if await readStatus() { return }
    guard agent == .unreachable else {
      recoveryAttempted = false
      return
    }
    Self.log.notice("the agent is enabled but does not answer; restarting it")
    guard await services.restartAgent() else { return }
    for _ in 0..<Self.recoveryChecks {
      guard (try? await sleep(Self.recoveryPause)) != nil else { return }
      if await readStatus() { return }
    }
    Self.log.error("the agent still does not answer after a restart")
  }
}
