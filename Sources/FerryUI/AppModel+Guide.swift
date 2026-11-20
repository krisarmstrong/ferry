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

  /// Whether the guide window should be brought forward now. True once per `showGuide`.
  func takeGuideOpenRequest() -> Bool {
    defer { guideOpenPending = false }
    return guideOpenPending
  }
}
