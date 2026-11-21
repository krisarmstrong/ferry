import DeviceKit
import FerryIPC
import Foundation

/// Starting the agent at launch, and restarting one launchd cannot start.
extension AppModel {
  /// After restarting an agent it could not reach, how many times the app asks it for its status,
  /// `recoveryPause` apart, before leaving it until the next outage.
  static let recoveryChecks = 5
  static let recoveryPause = Duration.seconds(1)
  /// How long a status request waits before the app looks for the agent's process.
  static let statusDeadline = Duration.seconds(5)
  /// After a restart, how many times the app looks for the agent's process, `startPoll` apart,
  /// before it removes the job launchd keeps.
  static let startChecks = 6
  static let startPoll = Duration.milliseconds(500)

  /// What one status request found.
  enum StatusRead: Equatable {
    case answered
    /// The connection to the agent was lost: nothing answers it (`.deviceDisconnected`).
    case lost
    /// The agent is there but failed the request: slow, or an unreadable reply.
    case failed
    /// The caller stopped, as when the menu closes: nothing was learnt, nothing is changed.
    case cancelled
  }

  /// Starts the agent, reads its status, then whether Ferry opens at login, and updates the adb
  /// Ferry fetched if this release pins a newer one. The system calls run off the main actor (see
  /// `SystemServices`), so the app opens without waiting on them.
  public func launch() async {
    noteFirstRun()
    restartedBuild = await startAgent()
    await refresh()
    // After the first status, so the menu's devices never wait on Launch Services.
    await services.registerExtensions()
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

  /// Sends `.status`. launchd holds a message for a job it lists, even one it cannot spawn, so a
  /// status to an agent that never starts never fails: the reply just never comes. Once
  /// `statusDeadline` has passed, the app looks for the agent's process. With none running the
  /// request is cancelled and fails as a lost connection; a live agent that is only slow is
  /// waited for, as before.
  func requestStatus() async throws(TransportError) -> AgentResponse {
    enum Outcome: Sendable {
      case reply(Result<AgentResponse, TransportError>)
      case deadline
    }
    let client = client
    let deadline = statusDeadline
    let result: Result<AgentResponse, TransportError> = await withTaskGroup(
      of: Outcome?.self
    ) { group in
      group.addTask {
        do throws(TransportError) {
          return .reply(.success(try await client.send(.status, file: nil)))
        } catch {
          return .reply(.failure(error))
        }
      }
      group.addTask { (try? await deadline()) == nil ? nil : .deadline }
      for await outcome in group {
        switch outcome {
        case .reply(let result):
          group.cancelAll()
          return result
        case .deadline:
          guard !Task.isCancelled, await !services.agentIsRunning() else { continue }
          Self.log.error("no answer to status and no agent process; the connection is lost")
          group.cancelAll()
          return .failure(.deviceDisconnected)
        case nil:
          continue
        }
      }
      return .failure(.cancelled)
    }
    return try result.get()
  }

  /// launchd can keep a job it can no longer spawn: after a build signed by another identity is
  /// installed, the job keeps the old identity's launch constraint and every spawn fails
  /// (`OS_REASON_CODESIGNING`, then `EX_CONFIG`), while `SMAppService` still says it is enabled.
  /// The restart at launch can come too early to clear it; one a few seconds later does. An
  /// agent the app cannot reach while macOS has it enabled is therefore restarted (unregistered,
  /// which removes the job, and registered again), once per outage: a restart cuts off every
  /// transfer. If no agent process appears within `startChecks` polls, the job is booted out of
  /// launchd and the agent restarted once more. Then the app asks for its status a bounded
  /// number of times. Only a lost connection counts: a status the menu cancelled by closing says
  /// nothing about the agent, a slow or garbled answer comes from an agent that runs, and a call
  /// lost because launchd relaunched the agent mid-call is answered when asked again, so none of
  /// these restarts it. Remove Ferry suppresses all of it. A restart also ends the adb server the
  /// agent runs.
  func recoverAgent() async {
    guard !Task.isCancelled, !recoveryAttempted, !removing else { return }
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
    guard await readStatus() == .lost, agent == .unreachable, !Task.isCancelled else {
      if agent != .running { recoveryAttempted = false }
      return
    }
    // Remove Ferry, or the user, may have unregistered the agent during the checks.
    guard !removing, await services.agentIsEnabled() else {
      recoveryAttempted = false
      return
    }
    await restartUnansweringAgent()
  }

  /// Restarts the agent, boots its job out if no agent process appears, then asks for its
  /// status a bounded number of times.
  private func restartUnansweringAgent() async {
    Self.log.notice("the agent is enabled but does not answer; restarting it")
    guard await services.restartAgent() else { return }
    switch await agentStarts() {
    case nil:
      return
    case false?:
      guard !removing else { return }
      Self.log.notice("the restarted agent did not start; removing its launchd job")
      await services.bootOutAgent()
      guard !removing, await services.restartAgent() else { return }
    case true?:
      break
    }
    for _ in 0..<Self.recoveryChecks {
      guard (try? await sleep(Self.recoveryPause)) != nil else { return }
      if await readStatus() == .answered { return }
    }
    Self.log.error("the agent still does not answer after a restart")
  }

  /// Whether an agent process appears within `startChecks` polls; `nil` if the caller stopped.
  private func agentStarts() async -> Bool? {
    for _ in 0..<Self.startChecks {
      if await services.agentIsRunning() { return true }
      guard (try? await sleep(Self.startPoll)) != nil else { return nil }
    }
    return await services.agentIsRunning()
  }
}
