import Foundation
import Testing

@testable import FerryUI

struct GuideStepsTests {
  @Test(arguments: [
    "LinkRunner-100G", "LinkRunner 100G", "linkrunner10g", "LinkRunner 10G", "EtherScope nXG",
    "ETHERSCOPE-NXG", "NetAlly LinkRunner 10G",
  ])
  func guideStepsForNetAllyModels(model: String) {
    #expect(GuideSteps.family(forModel: model) == .netAllyAndroid8Board)
    let steps = GuideSteps.steps(for: .netAllyAndroid8Board).map { String(localized: $0) }
    #expect(steps.count == 3)
    #expect(steps.contains { $0.contains("Transfer files") })
  }

  @Test(arguments: ["Pixel 8", "", "LinkRunner AT 4000", "AirCheck G3", "EtherScope"])
  func unknownModelHasNoFamily(model: String) {
    #expect(GuideSteps.family(forModel: model) == nil)
  }

  @Test func genericAndroidStepsNameTheirSetting() {
    let older = GuideSteps.steps(for: .otherAndroid8to9).map { String(localized: $0) }
    let newer = GuideSteps.steps(for: .otherAndroid10Plus).map { String(localized: $0) }
    #expect(older.contains { $0.contains("USB charging this device") })
    #expect(older.contains { $0.contains("Transfer files") })
    #expect(newer.contains { $0.contains("Charging this device via USB") })
    #expect(newer.contains { $0.contains("File transfer") })
    #expect(newer.contains { $0.contains("Unlock") })
  }

  @Test func everyFamilyHasStepsAndATitle() {
    for family in DeviceFamily.allCases {
      #expect(!GuideSteps.steps(for: family).isEmpty)
      #expect(!String(localized: family.title).isEmpty)
    }
  }

  private static func debugging(_ family: DeviceFamily) -> [String] {
    GuideSteps.steps(for: family, topic: .usbDebugging).map { String(localized: $0) }
  }

  @Test func theTopicChoosesTheSteps() {
    for family in DeviceFamily.allCases {
      #expect(GuideSteps.steps(for: family, topic: .fileTransfer) == GuideSteps.steps(for: family))
      #expect(GuideSteps.steps(for: family, topic: .usbDebugging) != GuideSteps.steps(for: family))
    }
  }

  /// The NetAlly steps, word for word: how a tester's ADB is enabled is NetAlly's to share, so
  /// the guide says only to ask, and nothing may be added to that.
  @Test func netAllyDebuggingStepsAreExactlyThese() {
    #expect(
      Self.debugging(.netAllyAndroid8Board) == [
        "Ask NetAlly to enable ADB on the tester.",
        "After that, on the tester: **Settings** → **System** → **About tester**. Tap "
          + "**Build number** until developer mode is on.",
        "Go to **Settings** → **System** → **Developer options** and turn on **USB debugging**.",
        "With the USB-C cable connected to the Mac, turn **USB debugging** off and on again. "
          + "The tester offers ADB only after this.",
        "On the device, tick **Always allow from this computer** and tap **OK**.",
      ])
  }

  @Test(arguments: DeviceFamily.allCases)
  func onlyTheNetAllyStepsNameNetAlly(family: DeviceFamily) {
    #expect(
      Self.debugging(family).contains { $0.contains("NetAlly") }
        == (family == .netAllyAndroid8Board))
  }

  @Test func genericAndroidDebuggingStepsNameTheirSettings() {
    let older = Self.debugging(.otherAndroid8to9)
    let newer = Self.debugging(.otherAndroid10Plus)
    for steps in [older, newer] {
      #expect(steps.contains { $0.contains("**Build number**") })
      #expect(steps.contains { $0.contains("**Developer options**") })
      #expect(steps.contains { $0.contains("**USB debugging**") })
      #expect(steps.last?.contains("**Always allow from this computer**") == true)
    }
    #expect(older.contains { $0.contains("**System** → **About phone**") })
    #expect(newer.contains { $0.contains("**About phone**") })
  }

  /// Every family's debugging steps end with the same note, which names no vendor and no port.
  @Test func theDebuggingNotePointsToConnectByAddress() {
    #expect(
      String(localized: GuideSteps.debuggingNote)
        == "If the device accepts ADB over the network, use **Connect by Address…**.")
  }

  @Test func everyTopicHasATitle() {
    for topic in GuideTopic.allCases { #expect(!String(localized: topic.title).isEmpty) }
  }

  /// Android 8 and 9 (and the NetAlly board, which runs Android 8) name the prompt's button OK;
  /// Android 10 and newer name it Allow.
  @Test(arguments: [
    (DeviceFamily.netAllyAndroid8Board, "**OK**"), (.otherAndroid8to9, "**OK**"),
    (.otherAndroid10Plus, "**Allow**"),
  ])
  func thePromptButtonIsNamedPerAndroidVersion(family: DeviceFamily, button: String) {
    let last = Self.debugging(family).last ?? ""
    #expect(last.contains("**Always allow from this computer**"))
    #expect(last.contains(button))
    #expect(last.contains(button == "**OK**" ? "**Allow**" : "**OK**") == false)
  }
}
