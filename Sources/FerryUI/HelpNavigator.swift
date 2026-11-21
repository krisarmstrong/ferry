import Foundation

/// What the Help window shows and how the reader moves through it: the search, the selected
/// topic, the message a Help link from the menu opened, and moving topic by topic from the
/// keyboard. A value, so the window's behaviour is tested without drawing it.
struct HelpNavigator: Equatable {
  let content: HelpContent
  var query = "" {
    didSet { shownCategories = content.categories(matching: query) }
  }
  private(set) var selection: String
  /// The categories and topics the search shows, worked out once per query.
  private(set) var shownCategories: [HelpCategory]
  /// The message a Help link opened, which the detail scrolls to and marks.
  private(set) var highlighted: String?
  /// How many Help links have opened a message, so the same link clicked again scrolls again.
  private(set) var linkRequests = 0

  init(content: HelpContent, selection: String) {
    self.content = content
    self.selection = selection
    shownCategories = content.categories
  }

  var shownTopics: [HelpTopic] { shownCategories.flatMap(\.topics) }

  /// The topic the sidebar selects and the detail shows: the chosen one if the search shows
  /// it, else the best match. `nil` when the search shows none.
  var shownTopic: HelpTopic? {
    shownTopics.first { $0.id == selection } ?? bestMatch
  }

  /// The first shown topic whose title matches the search, else the first shown.
  private var bestMatch: HelpTopic? {
    let shown = shownTopics
    let query = HelpSearchIndex.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !query.isEmpty else { return shown.first }
    return shown.first { content.searchIndex[$0.id]?.title.contains(query) == true }
      ?? shown.first
  }

  /// The sidebar chose a topic. It clears its selection while a search is typed, which keeps
  /// the topic chosen.
  mutating func select(_ id: String?) {
    guard let id else { return }
    selection = id
    highlighted = nil
  }

  /// The previous or next topic the search shows, from the one shown; stops at either end.
  mutating func move(by offset: Int) {
    let shown = shownTopics
    guard let current = shownTopic, let index = shown.firstIndex(of: current) else { return }
    select(shown[min(max(index + offset, 0), shown.count - 1)].id)
  }

  /// Return in the search field: opens the best match. False when nothing matches.
  mutating func submitSearch() -> Bool {
    guard let best = bestMatch else { return false }
    select(best.id)
    return true
  }

  /// A Help link from the menu: clears the search, which could hide the topic, opens the topic
  /// that explains the message and marks it. False, changing nothing, for a message Help does
  /// not explain.
  mutating func open(message key: String) -> Bool {
    guard let topic = content.topic(forMessage: key) else { return false }
    query = ""
    selection = topic.id
    highlighted = key
    linkRequests += 1
    return true
  }

  /// A welcome step's Help link: clears the search and opens the topic with this id, nothing
  /// marked. False, changing nothing, for an id Help does not have.
  mutating func open(topic id: String) -> Bool {
    guard content.topics.contains(where: { $0.id == id }) else { return false }
    query = ""
    select(id)
    return true
  }
}
