import DeviceKit
import FerryIPC
import SwiftUI

/// Port Forwarding in a device's expansion: a disclosure row, and while it is open the forwards
/// adb holds for the device ("Mac 8080 → Device 80", each with a remove button) and a line to
/// add one. A port the rules refuse, or adb's words when it refused, show under the line.
struct PortForwardRows: View {
  let tools: ToolActions

  var body: some View {
    MenuRow(
      title: Text(DevicePresentation.MenuAction.portForwarding.title),
      symbol: DevicePresentation.MenuAction.portForwarding.symbol,
      indent: MenuMetrics.actionIndent, isExpanded: tools.forwards != nil,
      action: tools.toggleForwards
    )
    .deviceAction(DevicePresentation.MenuAction.portForwarding.title, on: tools.name)
    if let session = tools.forwards {
      ForwardsList(session: session)
        .font(.callout)
        // Under the row's title, past its symbol.
        .padding(
          .leading,
          MenuMetrics.rowPadding + MenuMetrics.actionIndent + MenuMetrics.symbolWidth + 8
        )
        .padding(.trailing, MenuMetrics.rowPadding)
        .padding(.bottom, 4)
    }
  }
}

private struct ForwardsList: View {
  @Bindable var session: PortForwardsSession

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if session.forwards.isEmpty {
        Text("No forwards", bundle: .module)
          .foregroundStyle(.secondary)
      }
      ForEach(session.forwards, id: \.self) { forward in
        HStack(spacing: 6) {
          Text(verbatim: DevicePresentation.forwardLine(forward))
            .monospacedDigit()
          Spacer(minLength: 6)
          Button {
            Task { await session.remove(forward) }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .disabled(session.isBusy)
          .help(Text(verbatim: DevicePresentation.removeForwardLabel(forward)))
          .accessibilityLabel(Text(verbatim: DevicePresentation.removeForwardLabel(forward)))
        }
      }
      HStack(spacing: 4) {
        TextField(text: $session.localPort, prompt: Text(verbatim: "8080")) {
          Text("Port on this Mac", bundle: .module)
        }
        .frame(width: 64)
        Text(verbatim: "→")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(text: $session.remotePort, prompt: Text(verbatim: "80")) {
          Text("Port on the device", bundle: .module)
        }
        .frame(width: 64)
        Spacer(minLength: 4)
        Button {
          Task { await session.add() }
        } label: {
          Text("Add", bundle: .module)
        }
        .disabled(session.isBusy)
      }
      .textFieldStyle(.roundedBorder)
      .controlSize(.small)
      .labelsHidden()
      // Return adds: the menu has no single default button, so it is the fields that submit.
      .onSubmit { Task { await session.add() } }
      if let error = session.error {
        HelpLinked(key: error.help) {
          Text(verbatim: error.text)
            .foregroundStyle(.red)
        }
      } else {
        Text("Ports on this Mac start at 1024.", bundle: .module)
          .foregroundStyle(.secondary)
      }
    }
  }
}
