import SwiftUI

/// The Help window: sections from `help.json` in a sidebar, the selected one on the right, and
/// a search field that narrows the sidebar.
public struct HelpView: View {
  public static let windowID = "help"
  public static let windowTitle = Text("Ferry Help", bundle: .module)

  /// The section last shown, kept across launches though the window itself is not restored.
  @AppStorage("help.section") private var selection = "getting-started"
  @State private var query = ""
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
      sectionsView(content)
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

  private func sectionsView(_ content: HelpContent) -> some View {
    let sections = content.sections(matching: query)
    let shown = content.shownSection(selection: selection, query: query)
    return NavigationSplitView {
      List(sections, selection: shownID(shown)) { section in
        Label {
          Text(HelpText.resource(section.title))
        } icon: {
          Image(systemName: section.symbol)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    } detail: {
      if let shown {
        HelpSectionDetail(section: shown, model: model)
      } else {
        ContentUnavailableView.search(text: query)
      }
    }
    .searchable(text: $query, placement: .toolbar)
    .frame(minWidth: 640, minHeight: 420)
    .onAppear {
      // A section remembered from an earlier help that no longer has it.
      let known = content.sections.contains { $0.id == selection }
      if !known, let first = content.sections.first {
        selection = first.id
      }
    }
  }

  /// The sidebar's selection is the section the detail shows.
  private func shownID(_ shown: HelpSection?) -> Binding<String?> {
    Binding(get: { shown?.id }, set: { if let id = $0 { selection = id } })
  }
}

/// One section: its title, its own blocks, then each group under a headline.
struct HelpSectionDetail: View {
  let section: HelpSection
  let model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(HelpText.resource(section.title))
          .font(.title2)
          .bold()
        HelpBodyView(blocks: section.body, model: model)
        ForEach(Array(section.groups.enumerated()), id: \.offset) { _, group in
          VStack(alignment: .leading, spacing: 10) {
            Text(HelpText.resource(group.title))
              .font(.headline)
            HelpBodyView(blocks: group.body, model: model)
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 560, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
  @State private var asked = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(role: .destructive) {
        confirming = true
      } label: {
        Text("Remove Ferry…", bundle: .module)
      }
      .buttonStyle(.bordered)
      if asked, let error = model.actionError {
        Text(verbatim: error)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(Text("Remove Ferry?", bundle: .module), isPresented: $confirming) {
      Button(role: .destructive) {
        asked = true
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
  if let section = HelpContent.bundled?.sections.first(where: { $0.id == "troubleshooting" }) {
    HelpSectionDetail(section: section, model: .preview([]))
      .frame(width: 460, height: 560)
  }
}
