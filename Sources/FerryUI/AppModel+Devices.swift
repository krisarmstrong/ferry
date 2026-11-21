import DeviceKit
import FerryIPC
import Foundation

/// The menu's device actions and what it asks of the model about devices.
extension AppModel {
  public func turnOnInFinder() {
    services.open(Self.loginItemsSettings)
  }

  /// Where the user allows Ferry's helper to run in the background.
  public func openLoginItems() {
    services.open(Self.loginItemsSettings)
  }

  /// An ejected device reports `.ejected`, which never opens the guide.
  public func eject(_ id: DeviceID) async {
    await perform(.eject(id))
  }

  /// Mounts an ejected device again.
  public func mount(_ id: DeviceID) async {
    await perform(.recheck(id))
  }

  /// Asks the agent to open a device again, after the app holding it quits.
  public func recheck(_ id: DeviceID) async {
    await perform(.recheck(id))
  }

  /// The transfers running on `device`.
  public func transfers(on device: DeviceID) -> [ActiveTransfer] {
    transfers.filter { $0.device == device }
  }

  /// No answer from the agent yet, so whether a device is attached is not known.
  public var isChecking: Bool { agent == .checking }

  /// Ferry's locations exist and are all off in Finder: not an error, but the user must turn
  /// Ferry on. With no location yet there is nothing to turn on.
  public var showsTurnOnRow: Bool {
    agent == .running && provider == .disabled
  }
}
