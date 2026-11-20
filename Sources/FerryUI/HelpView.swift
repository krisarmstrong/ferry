import SwiftUI

/// The Help window: short topics under category headings in a sidebar, the selected one on the
/// right, and a search field that narrows the sidebar. A Help link beside a problem in the menu
/// opens the topic that explains it (see `AppModel.showHelp(forMessage:)`).
///
/// From the keyboard: the arrow keys move through the sidebar, Return in the search field opens
/// the first match, and ⌘[ and ⌘] go to the previous and next topic from anywhere.
public struct HelpView: View {
  public static let windowID = "help"
  public static let windowTitle = Text("Ferry Help", bundle: .module)

  /// Where the topic last shown is kept across launches; the window itself is not restored.
  static let selectionKey = "help.topic"

  private let model: AppModel
  private let content: HelpContent?

  public init(model: AppModel) {
    self.init(model: model, content: .bundled)
  }

  init(model: AppModel, content: HelpContent?) {
    self.model = model
    self.content = content
  }

  public var body: some View {
    if let content {
      HelpBrowser(model: model, content: content)
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

  init(model: AppModel, content: HelpContent) {
    self.model = model
    let stored = UserDefaults.standard.string(forKey: HelpView.selectionKey) ?? ""
    _navigator = State(initialValue: HelpNavigator(content: content, selection: stored))
  }

  var body: some View {
    NavigationSplitView {
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
      .focused($sidebarFocused)
      .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    } detail: {
      if let shown = navigator.shownTopic {
        HelpTopicDetail(topic: shown, highlighted: navigator.highlighted, model: model)
      } else {
        ContentUnavailableView.search(text: navigator.query)
      }
    }
    .searchable(text: $navigator.query, placement: .toolbar)
    .onSubmit(of: .search) {
      if navigator.submitSearch() { sidebarFocused = true }
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          navigator.move(by: -1)
        } label: {
          Label {
            Text("Previous Topic", bundle: .module)
          } icon: {
            Image(systemName: "chevron.up")
          }
        }
        .keyboardShortcut("[")
        .help(Text("Previous Topic", bundle: .module))
        Button {
          navigator.move(by: 1)
        } label: {
          Label {
            Text("Next Topic", bundle: .module)
          } icon: {
            Image(systemName: "chevron.down")
          }
        }
        .keyboardShortcut("]")
        .help(Text("Next Topic", bundle: .module))
      }
    }
    .frame(minWidth: 680, minHeight: 440)
    .onAppear { model.helpAppeared() }
    .onChange(of: model.helpRequest, initial: true) { _, _ in
      if let key = model.takeHelpRequest() { _ = navigator.open(message: key) }
    }
    .onChange(of: navigator.selection) { _, selection in
      UserDefaults.standard.set(selection, forKey: HelpView.selectionKey)
    }
  }

  /// The sidebar's selection is the topic the detail shows.
  private var selection: Binding<String?> {
    Binding(get: { navigator.shownTopic?.id }, set: { navigator.select($0) })
  }
}

/// One topic: its title, its own blocks, each group under a headline, then the messages it
/// explains. A message a Help link opened is scrolled to and marked.
struct HelpTopicDetail: View {
  let topic: HelpTopic
  let highlighted: String?
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
      .onChange(of: highlighted, initial: true) { _, key in
        guard let key else { return }
        proxy.scrollTo(key, anchor: .top)
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
    .accessibilityElement(children: .combine)
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
      if blocks.action == .removeFerry {
        RemoveFerryButton(model: model)
      }
    }
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

#Preview("Troubleshooting") {
  if let topic = HelpContent.bundled?.topics.first(where: { $0.id == "trouble-device" }) {
    HelpTopicDetail(topic: topic, highlighted: "Cancelled.", model: .preview([]))
      .frame(width: 520, height: 600)
  }
}
