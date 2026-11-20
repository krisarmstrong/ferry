import Foundation

/// The menu's lines that report a problem with a fixed message. Each has an entry in Help under
/// its key, which the line's Help link opens.
enum MenuStatusText {
  static let helperNotResponding = LocalizedStringResource(
    "Ferry's helper is not responding. Quit Ferry and open it again.", bundle: .module)
  static let allowHelper = LocalizedStringResource("Allow Ferry's helper", bundle: .module)
  static let helperNotFound = LocalizedStringResource(
    "macOS can't find Ferry's helper", bundle: .module)
  static let updated = LocalizedStringResource(
    "Ferry was updated. Quit and reopen Ferry.", bundle: .module)
  static let turnOnInFinder = LocalizedStringResource("Turn on Ferry in Finder", bundle: .module)
  static let noDevice = LocalizedStringResource("No device connected", bundle: .module)
  static let adbNotRunning = LocalizedStringResource("adb isn't running", bundle: .module)
  static let installADB = LocalizedStringResource("Install adb for more tools…", bundle: .module)
  static let usbWatchFailed = LocalizedStringResource(
    "Ferry can't watch USB for devices, so it looks for them every 30 seconds.", bundle: .module)
  static let chooseTransferFiles = LocalizedStringResource(
    "Choose Transfer files on the device.", bundle: .module)
  static let busy = LocalizedStringResource(
    "Quit Image Capture or Android File Transfer, then try again.", bundle: .module)
  static let allowUSBDebugging = LocalizedStringResource(
    "Allow USB debugging on the device", bundle: .module)
  static let recordingUnsaved = LocalizedStringResource(
    "Recording couldn't be saved", bundle: .module)

  static let all = [
    helperNotResponding, allowHelper, helperNotFound, updated, turnOnInFinder, noDevice,
    adbNotRunning, installADB, usbWatchFailed, chooseTransferFiles, busy, allowUSBDebugging,
    recordingUnsaved,
  ]
}
