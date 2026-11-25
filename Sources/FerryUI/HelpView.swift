import SwiftUI

/// The Help window: short topics under category headings in a sidebar, the selected one on the
/// right, and a search field that narrows the sidebar. A Help link beside a problem in the menu
/// opens the topic that explains it (see `AppModel.showHelp(forMessage:)`).
///
/// From the keyboard: the arrow keys move through the sidebar, Return in the search field opens
/// the best match (a title match first), ⌘F goes to the search field, and ⌘[ and ⌘] go to the
/// previous and next topic from anywhere.
public struct HelpView: View {
  public static let windowID = "help"
  public static let windowTitle = Text("Ferry Help", bundle: .module)

  /// Where the topic last shown is kept across launches; the window itself is not restored.
  static let selectionKey = "help.topic"

  private let model: AppModel
  private let content: HelpContent?
  /// A search to open with, for previews and snapshots.
  private let query: String

  public init(model: AppModel) {
    self.init(model: model, content: .bundled)
  }

  init(model: AppModel, content: HelpContent?, query: String = "") {
    self.model = model
    self.content = content
    self.query = query
  }

  public var body: some View {
    if let content {
      HelpBrowser(model: model, content: content, query: query)
    } else {
      ContentUnavailableView {
        Label {
          Text("Help isn't available", bundle: .module)
        } icon: {
          Image(systemName: "questionmark.circle")
        }
      } description: {
        Text("Ferry's help could not be loaded. Reinstalling Ferry restores it.", bundle: .module)
      }
      .frame(minWidth: 640, minHeight: 420)
    }
  }
}

/// The sidebar, the detail and the search, driven by a `HelpNavigator`.
private struct HelpBrowser: View {
  let model: AppModel
  @State private var navigator: HelpNavigator
  @FocusState private var sidebarFocused: Bool
  @FocusState private var searchFocused: Bool

  init(model: AppModel, content: HelpContent, query: String) {
    self.model = model
    let stored = UserDefaults.standard.string(forKey: HelpView.selectionKey) ?? ""
    var navigator = HelpNavigator(content: content, selection: stored)
    navigator.query = query
    _navigator = State(initialValue: navigator)
  }

  var body: some View {
    NavigationSplitView {
      HelpSidebar(navigator: $navigator)
        .focused($sidebarFocused)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    } detail: {
      HelpDetail(navigator: navigator, model: model)
    }
    .searchable(text: $navigator.query, placement: .toolbar)
    .searchFocused($searchFocused)
    // ⌘F, as in any window that searches: Ferry has no menu bar to carry Find.
    .onKeyPress(keys: ["f"]) { press in
      guard press.modifiers == .command else { return .ignored }
      searchFocused = true
      return .handled
    }
    .onSubmit(of: .search) {
      if navigator.submitSearch() { sidebarFocused = true }
    }
    .toolbar { stepButtons }
    .frame(minWidth: 680, minHeight: 440)
    .onAppear { model.helpAppeared() }
    .onChange(of: model.helpRequest, initial: true) { _, _ in
      switch model.takeHelpRequest() {
      case .message(let key)?: _ = navigator.open(message: key)
      case .topic(let id)?: _ = navigator.open(topic: id)
      case nil: break
      }
    }
    .onChange(of: navigator.selection) { _, selection in
      UserDefaults.standard.set(selection, forKey: HelpView.selectionKey)
    }
  }

  /// Previous Topic and Next Topic, ⌘[ and ⌘].
  @ToolbarContentBuilder private var stepButtons: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      HelpStepButton(title: "Previous Topic", symbol: "chevron.up", key: "[") {
        navigator.move(by: -1)
      }
      HelpStepButton(title: "Next Topic", symbol: "chevron.down", key: "]") {
        navigator.move(by: 1)
      }
    }
  }
}

/// The topics the search shows, under their category headings.
private struct HelpSidebar: View {
  @Binding var navigator: HelpNavigator

  var body: some View {
    List(selection: selection) {
      ForEach(navigator.shownCategories, id: \.title) { category in
        Section {
          ForEach(category.topics) { topic in
            Label {
              Text(HelpText.resource(topic.title))
            } icon: {
              Image(systemName: topic.symbol)
            }
            .tag(topic.id)
          }
        } header: {
          Text(HelpText.resource(category.title))
        }
      }
    }
  }

  /// The sidebar's selection is the topic the detail shows.
  private var selection: Binding<String?> {
    Binding(get: { navigator.shownTopic?.id }, set: { navigator.select($0) })
  }
}

/// The topic shown, or that the search found nothing.
private struct HelpDetail: View {
  let navigator: HelpNavigator
  let model: AppModel

  var body: some View {
    if let shown = navigator.shownTopic {
      HelpTopicDetail(
        topic: shown, highlighted: navigator.highlighted, linkRequest: navigator.linkRequests,
        model: model)
    } else {
      ContentUnavailableView.search(text: navigator.query)
    }
  }
}

/// A toolbar button that steps through the topics.
private struct HelpStepButton: View {
  let title: LocalizedStringResource
  let symbol: String
  let key: KeyEquivalent
  let action: () -> Void

  init(
    title: String.LocalizationValue, symbol: String, key: KeyEquivalent,
    action: @escaping () -> Void
  ) {
    self.title = LocalizedStringResource(title, bundle: .module)
    self.symbol = symbol
    self.key = key
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label {
        Text(title)
      } icon: {
        Image(systemName: symbol)
      }
    }
    .keyboardShortcut(key)
    .help(Text(title))
  }
}

/// One topic: its title, its own blocks, each group under a headline, then the messages it
/// explains. A message a Help link opened is scrolled to and marked.
struct HelpTopicDetail: View {
  let topic: HelpTopic
  let highlighted: String?
  /// Changes with each Help link, so a second click on the same one scrolls again.
  var linkRequest = 0
  let model: AppModel

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(HelpText.resource(topic.title))
            .font(.title2)
            .bold()
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h1)
          HelpBodyView(blocks: topic.body, model: model)
          ForEach(Array(topic.groups.enumerated()), id: \.offset) { _, group in
            VStack(alignment: .leading, spacing: 10) {
              Text(HelpText.resource(group.title))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)
              HelpBodyView(blocks: group.body, model: model)
            }
          }
          ForEach(topic.messages, id: \.message) { message in
            HelpMessageView(message: message, isHighlighted: message.message == highlighted)
              .id(message.message)
          }
        }
        .padding(24)
        .frame(maxWidth: 580, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: linkRequest, initial: true) {
        guard let highlighted else { return }
        proxy.scrollTo(highlighted, anchor: .top)
      }
    }
  }
}

/// A message in its exact words, then why it appears and what to do.
private struct HelpMessageView: View {
  let message: HelpMessage
  let isHighlighted: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(HelpText.resource(message.wording))
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHeading(.h2)
      Text(HelpText.attributed(message.cause))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(HelpText.attributed(message.fix))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(isHighlighted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quinary))
    }
    // Kept as separate elements: combined, the wording's heading would swallow the cause and fix.
    .accessibilityElement(children: .contain)
  }
}

/// Paragraphs, numbered steps, definitions, note, link and action, in that order.
private struct HelpBodyView: View {
  @Environment(\.openWindow) private var openWindow
  let blocks: HelpBody
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.paragraphs.enumerated()), id: \.offset) { _, paragraph in
        Text(HelpText.attributed(paragraph))
          .fixedSize(horizontal: false, vertical: true)
      }
      if !blocks.steps.isEmpty {
        NumberedSteps(steps: blocks.steps.map(HelpText.resource))
      }
      if !blocks.definitions.isEmpty {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
          ForEach(Array(blocks.definitions.enumerated()), id: \.offset) { _, definition in
            GridRow {
              Text(HelpText.resource(definition.term))
                .fontWeight(.semibold)
              Text(HelpText.attributed(definition.detail))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      if let note = blocks.note {
        Text(HelpText.attributed(note))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let link = blocks.link {
        Button {
          model.showGuide(family: link.family, topic: link.topic)
          _ = model.takeGuideOpenRequest()
          openWindow(id: SetupGuide.windowID)
        } label: {
          Text(HelpText.resource(link.title))
        }
        .buttonStyle(.bordered)
      }
      switch blocks.action {
      case .removeFerry?:
        RemoveFerryButton(model: model)
      case .copyDiagnostics?:
        CopyDiagnosticsButton(model: model)
      case .showWelcome?:
        Button {
          model.showWelcome()
          _ = model.takeWelcomeOpenRequest()
          openWindow(id: WelcomeView.windowID)
        } label: {
          Text("Show Welcome Window", bundle: .module)
        }
        .buttonStyle(.bordered)
      case nil:
        EmptyView()
      }
    }
  }
}

/// Copy Diagnostics: puts the report on the pasteboard and says Copied beside the button.
private struct CopyDiagnosticsButton: View {
  let model: AppModel
  @State private var copied = false

  var body: some View {
    HStack(spacing: 8) {
      Button {
        model.copyDiagnostics()
        copied = true
      } label: {
        Text("Copy Diagnostics", bundle: .module)
      }
      .buttonStyle(.bordered)
      if copied {
        Text(DevicePresentation.copiedResource)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// Remove Ferry…: confirms, then removes Ferry's locations and helper and quits. If that fails,
/// the reason shows here, where the reader asked for it.
private struct RemoveFerryButton: View {
  let model: AppModel
  @State private var confirming = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(role: .destructive) {
        confirming = true
      } label: {
        Text("Remove Ferry…", bundle: .module)
      }
      .buttonStyle(.bordered)
      if let error = model.removalError {
        Text(verbatim: error)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(Text("Remove Ferry?", bundle: .module), isPresented: $confirming) {
      Button(role: .destructive) {
        Task { await model.removeFerry() }
      } label: {
        Text("Remove Ferry", bundle: .module)
      }
    } message: {
      Text(
        """
        Your devices disappear from Finder, Ferry's helper stops, and Ferry quits. Files on \
        your devices are not touched. You can then move Ferry to the Trash.
        """, bundle: .module)
    }
  }
}

#Preview("Help") {
  HelpView(model: .preview([]))
}

#Preview("Search") {
  HelpView(model: .preview([]), content: .bundled, query: "recording")
}

#Preview("Troubleshooting") {
  if let topic = HelpContent.bundled?.topics.first(where: { $0.id == "trouble-device" }) {
    HelpTopicDetail(topic: topic, highlighted: "Cancelled.", model: .preview([]))
      .frame(width: 520, height: 600)
  }
}
