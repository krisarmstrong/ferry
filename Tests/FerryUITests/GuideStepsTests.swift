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
}
