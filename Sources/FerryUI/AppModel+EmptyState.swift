import DeviceKit
import FerryIPC

/// What the menu shows when Ferry has no device yet, and when it offers adb.
extension AppModel {
  /// Any device in the menu: attached, remembered on the network, waiting for Allow on it, or
  /// an address waiting for the user to confirm it.
  public var hasDevices: Bool {
    !devices.isEmpty || !remembered.isEmpty || !awaitingAuthorization.isEmpty
      || !unconfirmed.isEmpty
  }

  /// "No device connected" and its file-transfer hint: only with no device at all.
  public var showsNoDevice: Bool { agent == .running && !hasDevices }

  /// Opens the guide, with the model picker, once per app run when the agent is running but
  /// has had no device for 10 s of the menu being open, counted from the agent's first answer.
  func considerEmptyGuide(openFor: Duration) {
    guard showsNoDevice, openFor >= Self.emptyGuideDelay, !emptyGuideShown else { return }
    emptyGuideShown = true
    showGuide(for: nil)
  }
}
