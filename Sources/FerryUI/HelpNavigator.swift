import Foundation

/// What the Help window shows and how the reader moves through it: the search, the selected
/// topic, the message a Help link from the menu opened, and moving topic by topic from the
/// keyboard. A value, so the window's behaviour is tested without drawing it.
struct HelpNavigator: Equatable {
  let content: HelpContent
  var query = ""
  private(set) var selection: String
  /// The message a Help link opened, which the detail scrolls to and marks.
  private(set) var highlighted: String?

  init(content: HelpContent, selection: String) {
    self.content = content
    self.selection = selection
  }

  var shownCategories: [HelpCategory] { content.categories(matching: query) }

  var shownTopics: [HelpTopic] { shownCategories.flatMap(\.topics) }

  /// The topic the sidebar selects and the detail shows: the chosen one if the search shows
  /// it, else the first shown. `nil` when the search shows none.
  var shownTopic: HelpTopic? {
    let shown = shownTopics
    return shown.first { $0.id == selection } ?? shown.first
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

  /// Return in the search field: opens the first match. False when nothing matches.
  mutating func submitSearch() -> Bool {
    guard let first = shownTopics.first else { return false }
    select(first.id)
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
    return true
  }
}
