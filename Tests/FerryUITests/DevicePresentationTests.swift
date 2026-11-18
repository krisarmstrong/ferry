import DeviceKit
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

  @Test func theInstallCommandIsExact() {
    #expect(DevicePresentation.installCommand == "brew install --cask android-platform-tools")
  }

  @Test func aWaitingAddressIsEscaped() {
    #expect(
      DevicePresentation.waitingLine(for: "192.0.2.31:5555")
        == "Waiting for Allow on 192.0.2.31:5555")
    #expect(!DevicePresentation.waitingLine(for: "a\u{202E}b:5555").contains("\u{202E}"))
  }
}
