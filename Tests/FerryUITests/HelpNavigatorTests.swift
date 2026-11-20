import Foundation
import Testing

@testable import FerryUI

/// The Help window's behaviour: search narrows the topics, a Help link from the menu opens the
/// topic that explains its message, and the keyboard moves topic by topic.
struct HelpNavigatorTests {
  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])

  private static func navigator(at selection: String = "getting-started") -> HelpNavigator {
    HelpNavigator(content: help, selection: selection)
  }

  // MARK: Search

  @Test(arguments: ["", "   "])
  func anEmptySearchShowsEveryTopic(query: String) {
    var navigator = Self.navigator()
    navigator.query = query
    #expect(navigator.shownCategories == Self.help.categories)
    #expect(navigator.shownTopics == Self.help.topics)
  }

  @Test func searchMatchesTitlesAndText() {
    var navigator = Self.navigator()
    navigator.query = "no analytics"
    #expect(navigator.shownTopics.map(\.id) == ["privacy"])
    navigator.query = "TELEMETRY"
    #expect(navigator.shownTopics.map(\.id) == ["privacy"])
    // A message's exact words, its cause and its fix are searched too.
    navigator.query = "MacDroid"
    #expect(navigator.shownTopics.map(\.id) == ["trouble-device"])
    navigator.query = "Paired, but the device"
    #expect(navigator.shownTopics.map(\.id) == ["trouble-network"])
  }

  /// "Tap **Transfer files**" reads "Tap Transfer files", so a search for that finds it.
  @Test func searchIgnoresMarkdownAndDiacritics() {
    var navigator = Self.navigator()
    navigator.query = "tap transfer files"
    #expect(navigator.shownTopics.map(\.id).contains("connect-tester"))
    #expect(navigator.shownTopics.map(\.id).contains("connect-android"))
    navigator.query = "Chécking…"
    #expect(navigator.shownTopics.map(\.id) == ["menu"])
  }

  /// A category none of whose topics match is left out of the sidebar.
  @Test func searchHidesCategoriesWithNoMatch() {
    var navigator = Self.navigator()
    navigator.query = "telemetry"
    #expect(navigator.shownCategories.map(\.title) == ["About Ferry"])
    navigator.query = "zzqx"
    #expect(navigator.shownCategories.isEmpty)
    #expect(navigator.shownTopic == nil)
  }

  /// The sidebar and the detail show the same topic: the chosen one if the search shows it,
  /// else the first shown; a remembered id the help no longer has falls back the same way.
  @Test func theShownTopicFollowsSelectionAndSearch() {
    var navigator = Self.navigator(at: "menu")
    #expect(navigator.shownTopic?.id == "menu")
    navigator.query = "MacDroid"
    #expect(navigator.shownTopic?.id == "trouble-device")
    navigator.query = ""
    #expect(navigator.shownTopic?.id == "menu")
    #expect(Self.navigator(at: "gone").shownTopic?.id == "getting-started")
  }

  /// Return in the search field opens the first match when no title matches, so the reader
  /// can go on with the arrow keys from there.
  @Test func returnInTheSearchOpensTheFirstMatch() {
    var navigator = Self.navigator(at: "menu")
    navigator.query = "logcat"
    let first = navigator.shownTopics.first?.id
    let found = navigator.submitSearch()
    #expect(found)
    #expect(navigator.selection == first)
    navigator.query = "zzqx"
    let foundNone = navigator.submitSearch()
    #expect(!foundNone)
    #expect(navigator.selection == first)
  }

  /// A topic whose title matches comes before one that only mentions the words, for Return and
  /// for what the detail shows; the sidebar keeps its order.
  @Test func aTitleMatchIsOpenedFirst() {
    var navigator = Self.navigator(at: "privacy")
    navigator.query = "screenshot"
    #expect(navigator.shownTopics.first?.id == "getting-started")
    #expect(navigator.shownTopic?.id == "screenshots")
    let found = navigator.submitSearch()
    #expect(found)
    #expect(navigator.selection == "screenshots")
  }

  // MARK: Keyboard

  /// ⌘[ and ⌘]; the sidebar's arrow keys are the list's own.
  @Test func theStepKeysMoveTopicByTopic() {
    let ids = Self.help.topics.map(\.id)
    var navigator = Self.navigator(at: ids[0])
    navigator.move(by: 1)
    #expect(navigator.selection == ids[1])
    navigator.move(by: 1)
    #expect(navigator.selection == ids[2])
    navigator.move(by: -1)
    #expect(navigator.selection == ids[1])
  }

  /// Moving crosses category headings and stops at either end rather than wrapping.
  @Test func movingStopsAtTheEnds() throws {
    let ids = Self.help.topics.map(\.id)
    var navigator = Self.navigator(at: ids[0])
    navigator.move(by: -1)
    #expect(navigator.selection == ids[0])
    let lastOfFirst = try #require(Self.help.categories.first?.topics.last?.id)
    navigator.select(lastOfFirst)
    navigator.move(by: 1)
    #expect(navigator.selection == Self.help.categories[1].topics.first?.id)
    navigator.select(try #require(ids.last))
    navigator.move(by: 1)
    #expect(navigator.selection == ids.last)
  }

  /// With a search, the keys move among the matches only. From a selection the search hides,
  /// they start at the topic shown.
  @Test func movingFollowsTheSearch() throws {
    var navigator = Self.navigator(at: "menu")
    navigator.query = "recording"
    let shown = navigator.shownTopics.map(\.id)
    #expect(!shown.contains("menu"))
    let start = try #require(shown.firstIndex(of: navigator.shownTopic?.id ?? ""))
    navigator.move(by: -1)
    #expect(navigator.selection == shown[start - 1])
    navigator.move(by: -1)
    #expect(navigator.selection == shown[start - 2])
  }

  // MARK: Deep links

  /// A Help link from the menu opens the topic that explains its message and marks the
  /// message there.
  @Test func aMessageOpensItsTopic() {
    var navigator = Self.navigator()
    let opened = navigator.open(message: "The device was disconnected.")
    #expect(opened)
    #expect(navigator.selection == "trouble-device")
    #expect(navigator.shownTopic?.id == "trouble-device")
    #expect(navigator.highlighted == "The device was disconnected.")
  }

  /// A search that hides the topic would otherwise show its first match instead: the link
  /// clears it.
  @Test func aMessageOpensItsTopicDuringASearch() {
    var navigator = Self.navigator()
    navigator.query = "telemetry"
    let opened = navigator.open(message: "adb: %@")
    #expect(opened)
    #expect(navigator.query.isEmpty)
    #expect(navigator.shownTopic?.id == "trouble-network")
  }

  /// A key Help does not know changes nothing.
  @Test func anUnknownMessageChangesNothing() {
    var navigator = Self.navigator(at: "menu")
    navigator.query = "logcat"
    let before = navigator
    let opened = navigator.open(message: "No such message")
    #expect(!opened)
    #expect(navigator == before)
  }

  /// Each Help link is a new request, so the same `?` clicked again scrolls to its entry again.
  @Test func theSameLinkTwiceIsTwoRequests() {
    var navigator = Self.navigator()
    _ = navigator.open(message: "The device was disconnected.")
    let first = navigator.linkRequests
    _ = navigator.open(message: "The device was disconnected.")
    #expect(navigator.linkRequests == first + 1)
  }

  /// Choosing another topic drops the mark.
  @Test func choosingATopicClearsTheMark() {
    var navigator = Self.navigator()
    _ = navigator.open(message: "The device was disconnected.")
    navigator.select("privacy")
    #expect(navigator.highlighted == nil)
    _ = navigator.open(message: "The device was disconnected.")
    navigator.move(by: 1)
    #expect(navigator.highlighted == nil)
  }

  /// The sidebar clears its selection while a search is typed: that keeps the topic chosen.
  @Test func aClearedSelectionKeepsTheTopic() {
    var navigator = Self.navigator(at: "menu")
    navigator.select(nil)
    #expect(navigator.selection == "menu")
  }
}

/// A Help link in the menu asks the Help window for its topic once.
@MainActor
struct HelpRequestTests {
  @Test func aHelpLinkIsTakenOnce() {
    let log = CallLog()
    let model = AppModel(client: FakeClient(log: log), services: FakeServices(log: log))
    #expect(model.takeHelpRequest() == nil)
    model.showHelp(forMessage: "The device was disconnected.")
    #expect(model.takeHelpRequest() == "The device was disconnected.")
    #expect(model.takeHelpRequest() == nil)
  }
}

/// Search reads a plain-text index built once with the help, not each string's Markdown on every
/// keystroke.
struct HelpSearchIndexTests {
  private static let help = HelpContent.bundled ?? HelpContent(version: 0, categories: [])

  @Test func theIndexHoldsEveryTopicFoldedOnce() throws {
    #expect(Self.help.searchIndex.count == Self.help.topics.count)
    let topic = try #require(Self.help.topics.first { $0.id == "menu" })
    let entry = try #require(Self.help.searchIndex["menu"])
    #expect(entry.title == HelpSearchIndex.folded(HelpText.plain(topic.title)))
    // Markdown is gone and case and diacritics are folded: "**Refresh**" reads "refresh".
    #expect(entry.text.contains { $0.contains("refresh") })
    #expect(!entry.text.contains { $0.contains("**") })
  }

  @Test func foldingIgnoresCaseDiacriticsAndWidth() {
    #expect(HelpSearchIndex.folded("Chécking ＡＢ") == "checking ab")
  }

  /// The navigator works out what the search shows once per query, not per read.
  @Test func theShownTopicsFollowTheQuery() {
    var navigator = HelpNavigator(content: Self.help, selection: "menu")
    navigator.query = "telemetry"
    #expect(navigator.shownTopics.map(\.id) == ["privacy"])
    navigator.query = ""
    #expect(navigator.shownTopics.count == Self.help.topics.count)
  }
}
