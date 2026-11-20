import SwiftUI

/// What an expanded device says about itself, after Control Center's Option-click Wi-Fi details:
/// a line per port or interface, its name on the left and its IPv4 address on the right, then
/// its Android version and battery. Clicking an address copies it; Option-clicking one copies
/// every detail. A port with no address is plain text. While the first read runs it says so in
/// one line; a failed read shows nothing.
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
            DetailLineContent(line: line, copied: nil)
              .padding(.horizontal, MenuMetrics.rowPadding)
              .padding(.vertical, 2)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                Text(verbatim: DevicePresentation.detailLabel(line, copied: nil)))
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

  /// The modifier keys are read as the click lands: Option copies every detail.
  private func addressLine(_ line: DevicePresentation.DetailLine) -> some View {
    let copied = tools.copied(line)
    return Button {
      tools.click(line, NSEvent.modifierFlags)
    } label: {
      DetailLineContent(line: line, copied: copied)
    }
    .buttonStyle(MenuRowStyle(verticalPadding: 2))
    .accessibilityLabel(Text(verbatim: DevicePresentation.detailLabel(line, copied: copied)))
    .accessibilityActions {
      Button {
        tools.copyAddress(line)
      } label: {
        Text(DevicePresentation.copyAddressResource(line))
      }
      Button {
        tools.copyAllDetails(line)
      } label: {
        Text(DevicePresentation.copyAllDetailsResource)
      }
    }
  }
}

/// A line's name, then its value on the trailing edge.
private struct DetailLineContent: View {
  let line: DevicePresentation.DetailLine
  let copied: CopiedWord?

  var body: some View {
    HStack(spacing: 8) {
      Text(verbatim: line.label)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      Group {
        if let copied {
          Text(DevicePresentation.copiedResource(copied))
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
