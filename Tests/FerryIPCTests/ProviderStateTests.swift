import FerryIPC
import Testing

struct ProviderStateTests {
  @Test(arguments: [
    ([], ProviderState.noDomains), ([false], .disabled), ([false, false], .disabled),
    ([false, true], .enabled), ([true], .enabled),
  ])
  func stateFollowsTheDomains(enabled: [Bool], state: ProviderState) {
    #expect(ProviderState(domains: enabled.map { (enabled: $0, hidden: false) }) == state)
  }

  /// A hidden domain (its device is away) is not in Finder, so it neither asks the user to turn
  /// Ferry on nor counts as turned on.
  @Test func hiddenDomainsAreNotCounted() {
    #expect(ProviderState(domains: [(enabled: false, hidden: true)]) == .noDomains)
    #expect(ProviderState(domains: [(enabled: true, hidden: true)]) == .noDomains)
    #expect(
      ProviderState(domains: [(enabled: false, hidden: true), (enabled: true, hidden: false)])
        == .enabled)
    #expect(
      ProviderState(domains: [(enabled: true, hidden: true), (enabled: false, hidden: false)])
        == .disabled)
  }
}
