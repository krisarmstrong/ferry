import SwiftUI

/// The Help window: sections from `help.json` in a sidebar, the selected one on the right, and
/// a search field that narrows the sidebar.
public struct HelpView: View {
  public static let windowID = "help"
  public static let windowTitle = Text("Ferry Help", bundle: .module)

  @SceneStorage("help.section") private var selection = "getting-started"
  @State private var query = ""
  private let model: AppModel
  private let content: HelpContent

  public init(model: AppModel) {
    self.init(model: model, content: .bundled)
  }

  init(model: AppModel, content: HelpContent) {
    self.model = model
    self.content = content
  }

  public var body: some View {
    let sections = content.sections(matching: query)
    NavigationSplitView {
      List(sections, selection: selectedID) { section in
        Label {
          Text(HelpText.resource(section.title))
        } icon: {
          Image(systemName: section.symbol)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    } detail: {
      if let section = sections.first(where: { $0.id == selection }) ?? sections.first {
        HelpSectionDetail(section: section, model: model)
      } else {
        ContentUnavailableView.search(text: query)
      }
    }
    .searchable(text: $query, placement: .toolbar)
    .frame(minWidth: 640, minHeight: 420)
  }

  private var selectedID: Binding<String?> {
    Binding(get: { selection }, set: { if let id = $0 { selection = id } })
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
        ForEach(section.groups, id: \.title) { group in
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

/// Paragraphs, numbered steps, definitions, note and link, in that order.
private struct HelpBodyView: View {
  @Environment(\.openWindow) private var openWindow
  let blocks: HelpBody
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(blocks.paragraphs, id: \.self) { paragraph in
        Text(HelpText.attributed(paragraph))
          .fixedSize(horizontal: false, vertical: true)
      }
      if !blocks.steps.isEmpty {
        NumberedSteps(steps: blocks.steps.map(HelpText.resource))
      }
      if !blocks.definitions.isEmpty {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
          ForEach(blocks.definitions, id: \.term) { definition in
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
          model.showGuide(family: link.family)
          _ = model.takeGuideOpenRequest()
          openWindow(id: SetupGuide.windowID)
        } label: {
          Text(HelpText.resource(link.title))
        }
        .buttonStyle(.bordered)
      }
    }
  }
}

#Preview("Help") {
  HelpView(model: .preview([]))
}

#Preview("Troubleshooting") {
  if let section = HelpContent.bundled.sections.first(where: { $0.id == "troubleshooting" }) {
    HelpSectionDetail(section: section, model: .preview([]))
      .frame(width: 460, height: 560)
  }
}
