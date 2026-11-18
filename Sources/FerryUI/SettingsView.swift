import AppKit
import SwiftUI

/// Settings: open at login, the setup guide, help, and removing Ferry.
public struct SettingsView: View {
  @Environment(\.openWindow) private var openWindow
  @State private var confirmingRemoval = false
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Form {
      Toggle(
        isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) })
      ) {
        Text("Open at login", bundle: .module)
      }
      LabeledContent {
        Button {
          model.showGuide(for: nil)
          _ = model.takeGuideOpenRequest()
          openWindow(id: SetupGuide.windowID)
        } label: {
          Text("How to connect", bundle: .module)
        }
      } label: {
        Text("File transfer", bundle: .module)
      }
      LabeledContent {
        Button {
          NSApp.activate()
          openWindow(id: HelpView.windowID)
        } label: {
          Text("Ferry Help", bundle: .module)
        }
      } label: {
        Text("Help", bundle: .module)
      }
      Section {
        Button(role: .destructive) {
          confirmingRemoval = true
        } label: {
          Text("Remove Ferry…", bundle: .module)
        }
      } footer: {
        if let error = model.actionError {
          Text(verbatim: error)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
    .confirmationDialog(
      Text("Remove Ferry?", bundle: .module), isPresented: $confirmingRemoval
    ) {
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

#Preview {
  SettingsView(model: .preview([]))
}
