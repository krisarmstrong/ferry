import Foundation
import Testing

@testable import FerryUI

/// Updates install by themselves by default, as the owner chose, and the menu's Install Updates
/// Automatically turns that off: it maps to Sparkle's `automaticallyDownloadsUpdates`, which
/// Sparkle keeps in Ferry's preferences (audit M4).
@MainActor
struct UpdateConsentTests {
  private func model(installs: Bool) -> (AppModel, FakeUpdater) {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    let updater = FakeUpdater(log: log)
    updater.installsAutomatically = installs
    model.updater = updater
    return (model, updater)
  }

  @Test func theToggleShowsSparklesSetting() {
    #expect(model(installs: true).0.installsUpdatesAutomatically)
    #expect(!model(installs: false).0.installsUpdatesAutomatically)
  }

  @Test func turningItOffTellsSparkle() {
    let (model, updater) = model(installs: true)
    model.setInstallsUpdatesAutomatically(false)
    #expect(!updater.installsAutomatically)
    #expect(!model.installsUpdatesAutomatically)
    model.setInstallsUpdatesAutomatically(true)
    #expect(updater.installsAutomatically)
  }

  /// A build that cannot update itself has no toggle to show, and the setting reads off.
  @Test func noUpdaterMeansNoAutomaticInstall() {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    #expect(!model.installsUpdatesAutomatically)
    model.setInstallsUpdatesAutomatically(true)
    #expect(!model.installsUpdatesAutomatically)
  }

  @Test func theToggleHasItsCatalogEntryAndHelp() throws {
    #expect(
      String(localized: MenuFooter.installUpdatesResource) == "Install Updates Automatically")
    let help = try #require(HelpContent.bundled)
    let updates = try #require(help.topics.first { $0.id == "updates" })
    #expect(updates.strings.contains { $0.contains("Install Updates Automatically") })
  }
}
