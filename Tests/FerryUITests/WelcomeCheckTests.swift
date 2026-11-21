import DeviceKit
import FerryIPC
import Testing

@testable import FerryUI

/// Which of the welcome's steps the user still has to take, read from the agent's status alone.
struct WelcomeCheckTests {
  private static func device(_ state: DeviceState) -> AttachedDevice {
    AttachedDevice(
      info: DeviceInfo(id: DeviceID(serial: "P1"), manufacturer: "Google", model: "Pixel 8"),
      state: state, method: .usbFileTransfer)
  }

  private static let ready = device(.ready([]))

  @Test(arguments: [AppModel.AgentState.checking, .unreachable, .replaced])
  func nothingIsKnownUntilTheAgentAnswers(agent: AppModel.AgentState) {
    #expect(
      WelcomeCheck(agent: agent, provider: .disabled, devices: [], adbStatus: .notInstalled)
        == nil)
  }

  @Test func aNewMacNeedsADevice() throws {
    let check = try #require(
      WelcomeCheck(agent: .running, provider: .noDomains, devices: [], adbStatus: .available))
    #expect(check.needed == [.connectDevice])
    #expect(check.done.isEmpty)
    #expect(!check.isComplete)
  }

  /// A device attached but not yet sharing, ejected, held by another app or failing is not yet
  /// in Finder: connecting it is what the step's guidance is for.
  @Test(arguments: [DeviceState.notSharingFiles, .ejected, .busy, .failed(.deviceBusy)])
  func onlyAReadyDeviceIsConnected(state: DeviceState) throws {
    let check = try #require(
      WelcomeCheck(
        agent: .running, provider: .noDomains, devices: [Self.device(state)],
        adbStatus: .available))
    #expect(check.needed == [.connectDevice])
  }

  @Test func finderOffIsAStep() throws {
    let check = try #require(
      WelcomeCheck(
        agent: .running, provider: .disabled, devices: [Self.ready], adbStatus: .available))
    #expect(check.needed == [.turnOnInFinder])
    #expect(!check.isComplete)
  }

  /// No location in Finder yet: there is nothing to turn on, so it is not a step, and not done
  /// either.
  @Test func noLocationIsNeitherAStepNorDone() throws {
    let check = try #require(
      WelcomeCheck(
        agent: .running, provider: .noDomains, devices: [Self.ready], adbStatus: .available))
    #expect(check.needed.isEmpty)
    #expect(!check.isComplete)
  }

  @Test func aReadyDeviceInFinderCompletesIt() throws {
    let check = try #require(
      WelcomeCheck(
        agent: .running, provider: .enabled, devices: [Self.ready], adbStatus: .available))
    #expect(check.needed.isEmpty)
    #expect(check.done == [.connectDevice, .turnOnInFinder])
    #expect(check.isComplete)
  }

  /// adb is optional: file transfer works without it. Missing, it is a step, and it never holds
  /// back completion.
  @Test func missingADBIsAnOptionalStep() throws {
    let check = try #require(
      WelcomeCheck(
        agent: .running, provider: .enabled, devices: [Self.ready], adbStatus: .notInstalled))
    #expect(check.needed == [.getPlatformTools])
    #expect(check.isComplete)
    #expect(WelcomeStep.getPlatformTools.isOptional)
    #expect(!WelcomeStep.connectDevice.isOptional)
    #expect(!WelcomeStep.turnOnInFinder.isOptional)
  }

  /// adb that is installed with its server down, or not yet looked for, is not missing.
  @Test(arguments: [ADBStatus.serverDown, nil])
  func adbNotMissingIsNoStep(adb: ADBStatus?) throws {
    let check = try #require(
      WelcomeCheck(agent: .running, provider: .enabled, devices: [Self.ready], adbStatus: adb))
    #expect(check.needed.isEmpty)
  }

  @Test func everyStepIsNeededAtOnce() throws {
    let check = try #require(
      WelcomeCheck(
        agent: .running, provider: .disabled, devices: [], adbStatus: .notInstalled))
    #expect(check.needed == Set(WelcomeStep.allCases))
  }

  /// The order the window lists them: a device first, since Finder has a location to turn on only
  /// once one has connected.
  @Test func stepsAreListedDeviceFirst() {
    #expect(WelcomeStep.allCases == [.connectDevice, .turnOnInFinder, .getPlatformTools])
  }

  /// Each step's Help link opens a topic Help has.
  @Test func eachStepLinksToAHelpTopic() throws {
    let help = try #require(HelpContent.bundled)
    let ids = Set(help.topics.map(\.id))
    for step in WelcomeStep.allCases {
      #expect(ids.contains(step.helpTopic), "\(step)")
    }
    #expect(ids.contains(AppModel.localNetworkHelpTopic))
  }
}
