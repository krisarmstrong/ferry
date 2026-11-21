import DeviceKit
import FerryIPC

extension AppModel {
  public func isAwaitingUSBDebugging(_ device: DeviceID) -> Bool {
    awaitingUSBDebugging.contains(device)
  }

  /// adb is installed but its server does not answer, and Ferry has a device that could use it
  /// or the user opened a network form: the same rule as the offer to get adb.
  public var showsADBNotRunning: Bool {
    agent == .running && adbStatus == .serverDown && (hasDevices || wantsNetwork)
  }

  /// The Check Again button: the agent looks for adb and starts its server.
  public func recheckADB() async {
    await perform(.recheckADB)
  }

  /// Opens the guide at the device's USB debugging steps, or the model picker if Ferry does not
  /// know its model or no device is given.
  public func showUSBDebuggingGuide(for device: AttachedDevice?) {
    showGuide(
      family: device.flatMap { GuideSteps.family(forModel: $0.info.model) },
      topic: .usbDebugging)
  }
}
