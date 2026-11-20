import SwiftUI

/// The menu's rows, after Control Center's Wi-Fi and Bluetooth menus: full width, highlighted
/// under the pointer or keyboard focus, with no border.
struct MenuRowStyle: ButtonStyle {
  /// Above and below the label: a detail line is tighter than an action row.
  var verticalPadding: CGFloat = 4

  func makeBody(configuration: Configuration) -> some View {
    Highlighted(configuration: configuration, verticalPadding: verticalPadding)
  }

  private struct Highlighted: View {
    let configuration: Configuration
    let verticalPadding: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
      configuration.label
        .padding(.horizontal, MenuMetrics.rowPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
          if isEnabled, hovering || isFocused || configuration.isPressed {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
          }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
  }
}

/// Where the menu lines things up.
enum MenuMetrics {
  /// Inside a row's highlight, before its content.
  static let rowPadding: CGFloat = 8
  static let tileSize: CGFloat = 26
  /// A device's action rows start under its name, past the tile.
  static let actionIndent: CGFloat = tileSize + 8
  /// A status row's text starts past its symbol; its action rows start there too.
  static let symbolWidth: CGFloat = 16
  static let statusIndent: CGFloat = symbolWidth + 8
}

/// A row that runs an action: an optional symbol, the title, and an optional shortcut hint on
/// the trailing edge. A row that discloses more below it has a chevron there instead, and
/// VoiceOver reads whether it is expanded.
struct MenuRow: View {
  let title: Text
  var symbol: String?
  var shortcut: String?
  var indent: CGFloat = 0
  var isExpanded: Bool?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let symbol {
          Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: MenuMetrics.symbolWidth)
            .accessibilityHidden(true)
        }
        title
          .lineLimit(1)
        Spacer(minLength: 8)
        if let shortcut {
          Text(verbatim: shortcut)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        if let isExpanded {
          DisclosureChevron(isExpanded: isExpanded)
        }
      }
      .padding(.leading, indent)
    }
    .buttonStyle(MenuRowStyle())
    .accessibilityValue(expandedValue)
  }

  private var expandedValue: Text {
    switch isExpanded {
    case true?: Text("Expanded", bundle: .module)
    case false?: Text("Collapsed", bundle: .module)
    case nil: Text(verbatim: "")
    }
  }
}

/// Points right while what it discloses is hidden, and down while it shows.
struct DisclosureChevron: View {
  let isExpanded: Bool

  var body: some View {
    Image(systemName: "chevron.right")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .accessibilityHidden(true)
  }
}

/// A line of the menu that is not a device: a symbol, what it says, any detail, and the rows
/// that act on it.
struct StatusRow<Detail: View, Actions: View>: View {
  let symbol: String
  var tint: Color?
  let title: Text
  /// The catalog key of the problem the row reports, whose Help entry its link opens.
  var help: String?
  @ViewBuilder var detail: Detail
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
          .frame(width: MenuMetrics.symbolWidth)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          title
            .fixedSize(horizontal: false, vertical: true)
          detail
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if help != nil {
          Spacer(minLength: 4)
          HelpLinkButton(key: help)
        }
      }
      .padding(.horizontal, MenuMetrics.rowPadding)
      .padding(.vertical, 4)
      actions
    }
  }
}

extension StatusRow where Detail == EmptyView {
  init(
    symbol: String, tint: Color? = nil, title: Text, help: String? = nil,
    @ViewBuilder actions: () -> Actions
  ) {
    self.init(
      symbol: symbol, tint: tint, title: title, help: help, detail: { EmptyView() },
      actions: actions)
  }
}

extension StatusRow where Detail == EmptyView, Actions == EmptyView {
  init(symbol: String, tint: Color? = nil, title: Text, help: String? = nil) {
    self.init(
      symbol: symbol, tint: tint, title: title, help: help, detail: { EmptyView() },
      actions: { EmptyView() })
  }
}

/// A status row's action, lined up with its text.
struct StatusAction: View {
  let title: Text
  let action: () -> Void

  var body: some View {
    MenuRow(title: title, indent: MenuMetrics.statusIndent, action: action)
  }
}

/// The round tile at the start of a device row.
struct DeviceTile: View {
  let tile: DevicePresentation.Tile

  var body: some View {
    Image(systemName: tile.symbol)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(tile.isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .frame(width: MenuMetrics.tileSize, height: MenuMetrics.tileSize)
      .background {
        if tile.isActive {
          Circle().fill(Color.accentColor)
        } else {
          Circle().fill(.quaternary)
        }
      }
      .accessibilityHidden(true)
  }
}

/// A row that expands in place: the tile, the name over its summary, and a chevron. VoiceOver
/// reads it as one button, "<name>, <summary>", expanded or collapsed.
struct ExpandingRowHeader: View {
  let tile: DevicePresentation.Tile
  let name: String
  let summary: String
  let isExpanded: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 8) {
        DeviceTile(tile: tile)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: name)
            .lineLimit(1)
          Text(verbatim: summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        DisclosureChevron(isExpanded: isExpanded)
      }
    }
    .buttonStyle(MenuRowStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: DevicePresentation.rowLabel(name: name, summary: summary)))
    .accessibilityValue(
      isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module)
    )
    .accessibilityAddTraits(.isButton)
  }
}

/// A thin line between the menu's sections, or, indented, between groups of a device's rows.
struct MenuSeparator: View {
  var indent: CGFloat = 0

  var body: some View {
    Divider()
      .padding(.leading, indent)
      .padding(.horizontal, MenuMetrics.rowPadding)
      .padding(.vertical, 4)
      .accessibilityHidden(true)
  }
}
