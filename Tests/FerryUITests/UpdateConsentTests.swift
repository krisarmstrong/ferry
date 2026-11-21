import Foundation
import Testing

@testable import FerryUI

/// Updates always install by themselves (owner, 2026-11-21): the menu has no toggle for it, and
/// Help does not offer one. Check for Updates… stays for anyone who wants a release now.
@MainActor
struct UpdateConsentTests {
  @Test func theMenuHasNoAutomaticInstallToggle() {
    #expect(!FerryUILabels.keys.contains("Install Updates Automatically"))
  }

  @Test func helpSaysUpdatesInstallByThemselves() throws {
    let help = try #require(HelpContent.bundled)
    let updates = try #require(help.topics.first { $0.id == "updates" })
    #expect(!updates.strings.contains { $0.contains("Install Updates Automatically") })
    #expect(updates.strings.contains { $0.contains("installs it the next time Ferry quits") })
  }
}
