import Foundation
import Testing

@testable import FerryProviderCore
@testable import FerrySyncCore

/// Send to and Finder's own location refuse packages and links in the same words, as the user
/// guide promises: the two modules keep a copy each, and this keeps them equal.
struct RefusalWordingTests {
  @Test func sendToAndTheFinderLocationSayTheSame() {
    #expect(LocalItem.Refusal.package.message == String(localized: ProviderText.package))
    #expect(LocalItem.Refusal.link.message == String(localized: ProviderText.link))
  }
}
