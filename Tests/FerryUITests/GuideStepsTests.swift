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

  @Test func netAllyDebuggingStepsFollowTheBoard() {
    let steps = Self.debugging(.netAllyAndroid8Board)
    #expect(steps.count == 5)
    #expect(steps[0] == "Ask NetAlly to enable ADB on the tester.")
    // These units take the developer-mode steps only once NetAlly has enabled ADB.
    #expect(steps[1].hasPrefix("After that,"))
    #expect(steps[1].contains("**Settings** → **System** → **About tester**"))
    #expect(steps[1].contains("**Build number**"))
    #expect(steps[2].contains("**Settings** → **System** → **Developer options**"))
    #expect(steps[2].contains("**USB debugging**"))
    // The board offers ADB only after the toggle is cycled with the cable in.
    #expect(steps[3].contains("cable") && steps[3].contains("off and on"))
    #expect(steps[4].contains("**Always allow from this computer**"))
  }

  /// How a NetAlly unit is unlocked is NetAlly's to share, not Ferry's.
  @Test(arguments: DeviceFamily.allCases)
  func noGuideDescribesTheUnlock(family: DeviceFamily) {
    for topic in GuideTopic.allCases {
      let steps = GuideSteps.steps(for: family, topic: topic).map { String(localized: $0) }
      for step in steps {
        #expect(!step.localizedCaseInsensitiveContains("unlockdetail"), "\(step)")
        #expect(!step.localizedCaseInsensitiveContains("code"), "\(step)")
        #expect(!step.localizedCaseInsensitiveContains("dial"), "\(step)")
      }
    }
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

  /// NetAlly testers listen for ADB over the network once ADB is enabled.
  @Test func onlyTheNetAllyBoardNotesNetworkADB() throws {
    let note = try #require(GuideSteps.debuggingNote(for: .netAllyAndroid8Board))
    #expect(String(localized: note).contains("5555"))
    #expect(GuideSteps.debuggingNote(for: .otherAndroid8to9) == nil)
    #expect(GuideSteps.debuggingNote(for: .otherAndroid10Plus) == nil)
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
