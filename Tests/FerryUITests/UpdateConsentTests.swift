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
    #expect(updates.strings.contains { $0.contains("**Update Ready — Restart Ferry**") })
  }

  /// L15: a menu app that opens at login rarely quits, so once Sparkle holds a downloaded update
  /// the menu offers to install it now, in place of Check for Updates….
  @Test func aReadyUpdateIsOfferedAndInstallsOnRestart() {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    model.updater = FakeUpdater(log: log)
    #expect(!model.updateReady)
    model.updateIsReady()
    #expect(model.updateReady)
    model.restartToUpdate()
    #expect(log.all == ["installUpdateAndRelaunch"])
    #expect(String(localized: MenuFooter.updateReadyResource) == "Update Ready — Restart Ferry")
  }
}
