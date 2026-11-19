import SwiftUI

/// What an expanded device says about itself, after Control Center's Option-click Wi-Fi details:
/// a line per port or interface, its name on the left and its IPv4 address on the right, then
/// its Android version and battery. Clicking an address copies it. While the first read runs it
/// says so in one line; a failed read shows nothing.
struct DetailLines: View {
  let tools: ToolActions

  var body: some View {
    switch tools.details {
    case .hidden:
      EmptyView()
    case .loading:
      Text(DevicePresentation.loadingDetailsResource)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, MenuMetrics.rowPadding + MenuMetrics.actionIndent)
        .padding(.bottom, 2)
    case .loaded(let info):
      VStack(alignment: .leading, spacing: 0) {
        ForEach(DevicePresentation.detailLines(info)) { line in
          if line.address == nil {
            DetailLineContent(line: line, copied: false)
              .padding(.horizontal, MenuMetrics.rowPadding)
              .padding(.vertical, 2)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                Text(verbatim: DevicePresentation.detailLabel(line, copied: false)))
          } else {
            addressLine(line)
          }
        }
        if let system = DevicePresentation.systemLine(info) {
          Text(verbatim: system)
            .foregroundStyle(.secondary)
            .padding(.leading, MenuMetrics.rowPadding + MenuMetrics.actionIndent)
            .padding(.vertical, 2)
        }
      }
      .font(.callout)
      .padding(.bottom, 2)
    }
  }

  private func addressLine(_ line: DevicePresentation.DetailLine) -> some View {
    let copied = tools.isCopied(line)
    return Button {
      tools.copyAddress(line)
    } label: {
      DetailLineContent(line: line, copied: copied)
    }
    .buttonStyle(MenuRowStyle(verticalPadding: 2))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: DevicePresentation.detailLabel(line, copied: copied)))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: Text(DevicePresentation.copyAddressResource(line))) {
      tools.copyAddress(line)
    }
  }
}

/// A line's name, then its value on the trailing edge.
private struct DetailLineContent: View {
  let line: DevicePresentation.DetailLine
  let copied: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text(verbatim: line.label)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      Group {
        if copied {
          Text(DevicePresentation.copiedResource)
        } else {
          Text(verbatim: line.value)
            .foregroundStyle(line.address == nil ? .secondary : .primary)
        }
      }
      .lineLimit(1)
      .monospacedDigit()
    }
    .padding(.leading, MenuMetrics.actionIndent)
  }
}

extension DetailsShown {
  var isLoaded: Bool {
    if case .loaded = self { true } else { false }
  }
}
