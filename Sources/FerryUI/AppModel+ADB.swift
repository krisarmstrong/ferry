import DeviceKit
import FerryIPC

extension AppModel {
  public func isAwaitingUSBDebugging(_ device: DeviceID) -> Bool {
    awaitingUSBDebugging.contains(device)
  }

  /// adb is missing and Ferry has a device that could use it, attached or on the network, or the
  /// user opened a network form. With neither the menu stays quiet: a Mac that never meets an
  /// Android device has no use for adb.
  public var showsInstallADB: Bool {
    agent == .running && adbStatus == .notInstalled && (hasDevices || wantsNetwork)
  }

  /// adb is installed but its server does not answer: the same rule as `showsInstallADB`.
  public var showsADBNotRunning: Bool {
    agent == .running && adbStatus == .serverDown && (hasDevices || wantsNetwork)
  }

  /// The Check Again button: the agent looks for adb and starts its server.
  public func recheckADB() async {
    await perform(.recheckADB)
  }

  public func copyInstallCommand() {
    services.copy(DevicePresentation.installCommand)
  }

  /// Opens the guide at the device's USB debugging steps, or the model picker if Ferry does not
  /// know its model or no device is given.
  public func showUSBDebuggingGuide(for device: AttachedDevice?) {
    showGuide(
      family: device.flatMap { GuideSteps.family(forModel: $0.info.model) },
      topic: .usbDebugging)
  }
}
