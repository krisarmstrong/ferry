import DeviceKit
import SwiftUI

/// What a device says about itself: model, Android version, build, serial number, battery,
/// IP addresses and storage. Read only; Copy puts the rows on the pasteboard.
public struct DeviceInfoView: View {
  public static let windowID = DeveloperWindow.deviceInfo.windowID
  public static let windowTitle = Text("Device Info", bundle: .module)

  @State private var session: DeviceInfoSession
  private let title: String

  public init(model: AppModel, device: DeviceID) {
    _session = State(initialValue: model.deviceInfoSession(for: device))
    title = model.modelName(of: device)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch session.state {
      case .loading:
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Reading the device…", bundle: .module)
        }
      case .loaded(let info):
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
          ForEach(DevicePresentation.infoRows(info), id: \.label) { row in
            GridRow {
              Text(verbatim: row.label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
              Text(verbatim: row.value)
                .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
          }
        }
      case .failed(let message):
        Text(verbatim: message)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button {
          Task { await session.load() }
        } label: {
          Text("Refresh", bundle: .module)
        }
        Button {
          session.copy()
        } label: {
          Text("Copy", bundle: .module)
        }
        .disabled(!isLoaded)
      }
    }
    .padding(20)
    .frame(minWidth: 380, alignment: .leading)
    .navigationTitle(Text(verbatim: DevicePresentation.infoTitle(model: title)))
    .task { await session.load() }
  }

  private var isLoaded: Bool {
    if case .loaded = session.state { true } else { false }
  }
}
