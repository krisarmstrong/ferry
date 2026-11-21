import DeviceKit
import FerryIPC

/// Something Ferry shows the user once, recorded in its defaults.
public enum OnboardingMark: String, Sendable, CaseIterable {
  /// The welcome was completed or closed: it never opens by itself again.
  case welcomeFinished = "onboarding.welcomeFinished"
  /// The menu has said, the first time the user reached for Wi-Fi, that macOS asks before Ferry
  /// uses the local network.
  case localNetworkExplained = "onboarding.localNetworkExplained"
}

/// A step of the welcome, in the order the window lists them: a device first, since Finder has a
/// location to turn on only once one has connected.
public enum WelcomeStep: String, Sendable, CaseIterable, Hashable {
  case connectDevice
  case turnOnInFinder
  /// adb, for USB debugging, Wi-Fi and a device's tools. File transfer works without it.
  case getPlatformTools

  /// Whether the setup is complete without it.
  var isOptional: Bool { self == .getPlatformTools }

  /// The Help topic that explains the step.
  var helpTopic: String {
    switch self {
    case .connectDevice: "first-device"
    case .turnOnInFinder: "turn-on-finder"
    case .getPlatformTools: "get-adb"
    }
  }
}

/// Which welcome steps the user still has to take, read from the agent's status. `nil` until the
/// agent answers: before that the model's provider and adb values are placeholders.
struct WelcomeCheck: Equatable {
  let needed: Set<WelcomeStep>
  /// Steps already taken, which the window lists ticked when it opens. adb that is there says
  /// nothing: it is listed only when missing.
  let done: Set<WelcomeStep>
  /// A device is ready and Ferry is on in Finder: the setup the welcome is for is done.
  let isComplete: Bool

  init?(
    agent: AppModel.AgentState, provider: ProviderState, devices: [AttachedDevice],
    adbStatus: ADBStatus?
  ) {
    guard agent == .running else { return nil }
    let connected = devices.contains {
      if case .ready = $0.state { true } else { false }
    }
    var needed = Set<WelcomeStep>()
    if !connected { needed.insert(.connectDevice) }
    // With no location in Finder there is nothing to turn on yet.
    if provider == .disabled { needed.insert(.turnOnInFinder) }
    if adbStatus == .notInstalled { needed.insert(.getPlatformTools) }
    self.needed = needed
    var done = Set<WelcomeStep>()
    if connected { done.insert(.connectDevice) }
    if provider == .enabled { done.insert(.turnOnInFinder) }
    self.done = done
    isComplete = connected && provider == .enabled
  }
}

/// A step the welcome lists, ticked once done.
struct WelcomeStepLine: Equatable, Hashable {
  let step: WelcomeStep
  let isDone: Bool
}

/// The welcome's state for this app run.
struct WelcomeState {
  /// Set by `launch()` when no agent was ever started on this Mac: Ferry is new here.
  var isFirstRun = false
  /// Whether this run has decided to show it or not, which the agent's first answer does.
  var decided = false
  var isPresented = false
  /// Cleared by the one view that brings the window forward.
  var openPending = false
  /// Every step listed since it opened, so a step done stays in the list, ticked.
  var listed: Set<WelcomeStep> = []
  /// The last check, while the agent answers.
  var check: WelcomeCheck?
}
