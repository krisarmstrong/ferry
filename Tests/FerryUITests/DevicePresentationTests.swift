import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

struct DevicePresentationTests {
  private static func attached(
    _ state: DeviceState, _ method: ConnectionMethod
  ) -> AttachedDevice {
    AttachedDevice(
      info: DeviceInfo(id: DeviceID(serial: "A"), manufacturer: "NetAlly", model: "EtherScope nXG"),
      state: state, method: method)
  }

  private static let ready = DeviceState.ready([])

  @Test(arguments: [
    (ConnectionMethod.usbADB, "USB · ADB"), (.wifiADB, "Wi-Fi · ADB"),
    (.usbFileTransfer, "USB · File transfer"),
  ])
  func methodIsNamedInPlainWords(method: ConnectionMethod, text: String) {
    #expect(String(localized: DevicePresentation.method(method)) == text)
  }

  @Test func everyMethodHasAName() {
    for method in ConnectionMethod.allCases {
      #expect(!String(localized: DevicePresentation.method(method)).isEmpty)
    }
  }

  /// A file-transfer device is offered USB debugging; one over ADB already has it.
  @Test(arguments: [
    (ConnectionMethod.usbFileTransfer, DevicePresentation.Hint?.some(.moreTools)),
    (.usbADB, nil), (.wifiADB, nil),
  ])
  func aReadyDeviceIsOfferedUSBDebuggingOnlyOverFileTransfer(
    method: ConnectionMethod, hint: DevicePresentation.Hint?
  ) {
    #expect(
      DevicePresentation.hint(for: Self.attached(Self.ready, method), awaitingUSBDebugging: false)
        == hint)
  }

  /// USB debugging is on and waiting for Allow: the device says so, however it is served.
  @Test(arguments: [ConnectionMethod.usbFileTransfer, .wifiADB])
  func aDeviceWaitingForAllowSaysSo(method: ConnectionMethod) {
    #expect(
      DevicePresentation.hint(for: Self.attached(Self.ready, method), awaitingUSBDebugging: true)
        == .allowUSBDebugging)
  }

  /// An unauthorised device adb lists alone is not sharing files, but file transfer is not what
  /// it needs.
  @Test func anUnauthorisedADBDeviceNeedsAllowNotTransferFiles() {
    let device = Self.attached(.notSharingFiles, .usbADB)
    #expect(DevicePresentation.hint(for: device, awaitingUSBDebugging: true) == .allowUSBDebugging)
    #expect(!DevicePresentation.needsFileTransferSteps(device))
  }

  @Test func aDeviceNotSharingOverFileTransferStillNeedsTheTransferSteps() {
    let device = Self.attached(.notSharingFiles, .usbFileTransfer)
    #expect(DevicePresentation.needsFileTransferSteps(device))
    #expect(DevicePresentation.hint(for: device, awaitingUSBDebugging: false) == nil)
  }

  @Test(arguments: [
    DeviceState.ejected, .busy, .failed(.deviceBusy),
  ])
  func otherStatesOfferNoHint(state: DeviceState) {
    #expect(
      DevicePresentation.hint(
        for: Self.attached(state, .usbFileTransfer), awaitingUSBDebugging: false)
        == nil)
  }

  @Test func theMethodShowsOnlyForAReadyDevice() {
    #expect(DevicePresentation.shownMethod(of: Self.attached(Self.ready, .usbADB)) == .usbADB)
    for state in [DeviceState.notSharingFiles, .ejected, .busy, .failed(.deviceBusy)] {
      #expect(DevicePresentation.shownMethod(of: Self.attached(state, .usbADB)) == nil)
    }
  }

  /// An unauthorised device only adb lists is waiting for Allow, not for file transfer.
  @Test func theStatusWordMatchesTheHint() {
    let waiting = Self.attached(.notSharingFiles, .usbADB)
    #expect(String(localized: DevicePresentation.status(of: waiting)) == "Waiting for Allow")
    let transfer = Self.attached(.notSharingFiles, .usbFileTransfer)
    #expect(String(localized: DevicePresentation.status(of: transfer)) == "Not sharing files")
    let ready = Self.attached(Self.ready, .usbADB)
    #expect(String(localized: DevicePresentation.status(of: ready)) == "Ready")
  }

  @Test func theInstallCommandIsExact() {
    #expect(DevicePresentation.installCommand == "brew install --cask android-platform-tools")
  }

  @Test func aWaitingAddressIsEscaped() {
    #expect(
      DevicePresentation.waitingLine(for: "192.0.2.31:5555")
        == "Waiting for you to allow this Mac on 192.0.2.31:5555")
    #expect(!DevicePresentation.waitingLine(for: "a\u{202E}b:5555").contains("\u{202E}"))
  }
}

struct ToolPresentationTests {
  private static func attached(_ state: DeviceState, _ method: ConnectionMethod) -> AttachedDevice {
    AttachedDevice(
      info: DeviceInfo(id: DeviceID(serial: "A"), manufacturer: "NetAlly", model: "LinkRunner"),
      state: state, method: method)
  }

  @Test(arguments: [
    (ConnectionMethod.usbADB, true), (.wifiADB, true), (.usbFileTransfer, false),
  ])
  func toolsAreOfferedOverADBOnly(method: ConnectionMethod, offered: Bool) {
    #expect(DevicePresentation.offersTools(Self.attached(.ready([]), method)) == offered)
    #expect(!DevicePresentation.offersTools(Self.attached(.ejected, method)))
    #expect(!DevicePresentation.offersTools(Self.attached(.notSharingFiles, method)))
  }

  @Test(arguments: [
    ("/tmp/a.apk", true), ("/tmp/A.APK", true), ("/tmp/a.apk.zip", false), ("/tmp/apk", false),
  ])
  func onlyAnAPKIsOffered(path: String, offered: Bool) {
    #expect(DevicePresentation.isAPK(URL(filePath: path)) == offered)
  }

  @Test(arguments: [
    ("INSTALL_FAILED_OLDER_SDK", "The app needs a newer version of Android."),
    ("INSTALL_FAILED_INSUFFICIENT_STORAGE", "The device doesn't have enough space for the app."),
    (
      "INSTALL_PARSE_FAILED_NO_CERTIFICATES",
      "The app couldn't be read by the device. It may be damaged or unsigned."
    ),
    // Unknown: the code itself.
    ("INSTALL_FAILED_SOMETHING_NEW", "Couldn't install the app: INSTALL_FAILED_SOMETHING_NEW"),
    // pm's own words, escaped.
    ("Error: \u{202E}evil", "Couldn't install the app: Error: \\u{202E}evil"),
  ])
  func pmsRefusalsReadPlainly(reason: String, message: String) {
    #expect(DevicePresentation.message(for: .installFailed(reason)) == message)
  }

  @Test func everyToolFailureHasAMessage() {
    for failure: ToolFailure in [
      .notOverADB, .notAnAPK, .apkTooLarge, .installFailed("X"), .alreadyRecording, .notRecording,
      .noImage, .recordingFailed(""), .recordingFailed("no encoder"), .cannotSave,
      .recordingTooLarge, .recordingStalled, .recordingBusy,
    ] {
      #expect(!DevicePresentation.message(for: failure).isEmpty)
    }
    #expect(
      DevicePresentation.message(for: .recordingFailed("bad\u{1B}[2J"))
        == "The device didn't record its screen: bad\\u{1B}[2J")
  }

  @Test func installProgressReadsAsCopyingThenInstalling() {
    #expect(
      DevicePresentation.installingLine(AppInstall(name: "a.apk", percent: 42))
        == "Copying “a.apk” to the device · 42%")
    #expect(
      DevicePresentation.installingLine(AppInstall(name: "a.apk", percent: 100))
        == "Installing “a.apk”…")
  }

  @Test func aMissingForwardReadsAsGone() {
    #expect(
      DevicePresentation.message(for: .forwardNotFound) == "That forward is already gone.")
  }

  @Test func developerToolFailuresReadInPlainWords() {
    #expect(
      DevicePresentation.message(for: .invalidPort)
        == "Use a port from 1024 to 65535 on this Mac and from 1 to 65535 on the device.")
    #expect(
      DevicePresentation.message(for: .adbNotFound)
        == "Ferry can't find adb. Install it, then try again.")
    #expect(
      DevicePresentation.message(
        for: .forwardFailed("cannot bind listener: Address already in use"))
        == "adb couldn't forward the port: cannot bind listener: Address already in use")
    #expect(
      DevicePresentation.message(for: .forwardFailed("a\u{1B}[2Jb"))
        == "adb couldn't forward the port: a\\u{1B}[2Jb")
  }
}
