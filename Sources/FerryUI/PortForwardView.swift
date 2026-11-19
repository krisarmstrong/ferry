import DeviceKit
import FerryIPC
import SwiftUI

/// A device's port forwards: connections to a port on this Mac reach a port on the device. The
/// list, a row to add one and a button to remove each.
public struct PortForwardView: View {
  public static let windowID = DeveloperWindow.portForwarding.windowID
  public static let windowTitle = Text("Port Forwarding", bundle: .module)

  @State private var session: PortForwardsSession
  private let title: String

  public init(model: AppModel, device: DeviceID) {
    _session = State(initialValue: model.portForwardsSession(for: device))
    title = model.modelName(of: device)
  }

  public var body: some View {
    @Bindable var session = session
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Connections to a port on this Mac reach a port on the device.", bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if session.forwards.isEmpty {
        Text("No forwards", bundle: .module)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(session.forwards, id: \.self) { forward in
            HStack {
              Text(verbatim: DevicePresentation.forwardLine(forward))
                .monospacedDigit()
              Spacer()
              Button {
                Task { await session.remove(forward) }
              } label: {
                Text("Remove", bundle: .module)
              }
              .accessibilityLabel(Text(verbatim: DevicePresentation.removeForwardLabel(forward)))
            }
          }
        }
      }
      Divider()
      HStack {
        TextField(text: $session.localPort, prompt: Text(verbatim: "8080")) {
          Text("Port on this Mac", bundle: .module)
        }
        Text(verbatim: "→")
          .accessibilityHidden(true)
        TextField(text: $session.remotePort, prompt: Text(verbatim: "80")) {
          Text("Port on the device", bundle: .module)
        }
        Button {
          Task { await session.add() }
        } label: {
          Text("Add", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(session.isBusy)
      }
      Text("Ports on this Mac start at 1024.", bundle: .module)
        .font(.callout)
        .foregroundStyle(.secondary)
      if let error = session.error {
        Text(verbatim: error)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(20)
    .frame(width: 460)
    .navigationTitle(Text(verbatim: DevicePresentation.forwardsTitle(model: title)))
    .task { await session.refresh() }
  }
}
