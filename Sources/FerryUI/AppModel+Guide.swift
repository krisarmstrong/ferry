import DeviceKit
import Foundation

/// Opening the setup guide, from the menu and from Help.
extension AppModel {
  /// Opens the guide with the device's steps, or the model picker if Ferry does not know its
  /// model or no device is given.
  public func showGuide(for device: AttachedDevice?) {
    showGuide(family: device.flatMap { GuideSteps.family(forModel: $0.info.model) })
  }

  /// Opens the guide with the family's steps, or the model picker for `nil`.
  public func showGuide(family: DeviceFamily?, topic: GuideTopic = .fileTransfer) {
    guideFamily = family
    guideTopic = topic
    isGuidePresented = true
    guideOpenPending = true
  }

  /// Opens the guide for a device that needs file transfer turned on, once per device and app
  /// run: not over a guide already open, nor while the welcome, which offers it, is up. A
  /// device seen meanwhile gets its guide once the welcome closes.
  func guideNewDevices() {
    guard !welcomeHoldsGuide else { return }
    for device in devices where DevicePresentation.needsFileTransferSteps(device) {
      guard guidedDevices.insert(device.id).inserted, !isGuidePresented else { continue }
      showGuide(for: device)
    }
  }

  /// Whether the guide window should be brought forward now. True once per `showGuide`.
  func takeGuideOpenRequest() -> Bool {
    defer { guideOpenPending = false }
    return guideOpenPending
  }
}
