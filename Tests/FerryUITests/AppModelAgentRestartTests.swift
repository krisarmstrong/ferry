import Testing

@testable import FerryUI

/// After an update the agent still running is the old one, which would serve the new app old
/// code until the next login. Launch restarts it whenever the agent in the bundle is not the one
/// it was last started from.
@MainActor
struct AppModelAgentRestartTests {
  let log = CallLog()

  @Test func unchangedAgentIsOnlyRegistered() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-1"
    services.startedAgent = "agent-1"
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(log.all == ["registerAgent", "status", "registerExtensions", "readLoginItem"])
  }

  @Test func updatedAgentIsRestartedBeforeTheFirstStatus() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-2"
    services.startedAgent = "agent-1"
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(
      log.all == [
        "restartAgent", "status", "recordStartedAgent agent-2", "registerExtensions",
        "readLoginItem",
      ])
    #expect(services.startedAgent == "agent-2")
  }

  /// The first launch, or the first after an update from a Ferry that recorded nothing: the agent
  /// running, if any, may be anything.
  @Test func agentNeverRecordedIsRestarted() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-1"
    services.startedAgent = nil
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(
      log.all == [
        "restartAgent", "status", "recordStartedAgent agent-1", "registerExtensions",
        "readLoginItem",
      ])
  }

  /// A restart that could not register the new agent records nothing, so the next launch tries
  /// again; meanwhile the menu shows the helper as unreachable, as for any agent that is down.
  @Test func aFailedRestartIsRetriedAtTheNextLaunch() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = "agent-2"
    services.startedAgent = "agent-1"
    services.restartSucceeds = false
    let model = AppModel(client: UnreachableClient(), services: services)
    await model.launch()
    #expect(log.all == ["restartAgent", "registerExtensions", "readLoginItem"])
    #expect(services.startedAgent == "agent-1")
    #expect(model.agent == .unreachable)

    services.restartSucceeds = true
    await AppModel(client: FakeClient(log: log), services: services).launch()
    #expect(
      log.all.suffix(5) == [
        "restartAgent", "status", "recordStartedAgent agent-2", "registerExtensions",
        "readLoginItem",
      ])
  }

  /// Without the agent's identity there is nothing to compare: registering is harmless, and a
  /// restart on every launch would cut off every transfer at each one.
  @Test func unreadableAgentIsOnlyRegistered() async {
    let services = FakeServices(log: log)
    services.agentOnDisk = nil
    services.startedAgent = "agent-1"
    let model = AppModel(client: FakeClient(log: log), services: services)
    await model.launch()
    #expect(log.all == ["registerAgent", "status", "registerExtensions", "readLoginItem"])
    #expect(services.startedAgent == "agent-1")
  }
}
