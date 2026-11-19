import AppKit
import SwiftUI

/// The rows at the foot of the menu: Open at Login, Help and Quit Ferry. Ferry has no Settings
/// window; Remove Ferry… is in Help, under Troubleshooting.
struct MenuFooter: View {
  static let openAtLoginResource = LocalizedStringResource("Open at Login", bundle: .module)

  @Environment(\.openWindow) private var openWindow
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Toggle(
        isOn: Binding(
          get: { model.opensAtLogin }, set: { model.requestOpensAtLogin($0) })
      ) {
        Text(Self.openAtLoginResource)
      }
      .toggleStyle(MenuToggleStyle())
      MenuRow(title: Text("Help", bundle: .module), shortcut: "⌘?") {
        NSApp.activate()
        openWindow(id: HelpView.windowID)
      }
      .keyboardShortcut("?")
      MenuRow(title: Text("Quit Ferry", bundle: .module), shortcut: "⌘Q") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}

/// A toggle drawn as a menu row: a checkmark before the title while it is on, as a menu item
/// shows one. VoiceOver reads it as a switch with its state.
struct MenuToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .font(.callout.weight(.semibold))
          .opacity(configuration.isOn ? 1 : 0)
          .frame(width: MenuMetrics.symbolWidth)
          .accessibilityHidden(true)
        configuration.label
          .lineLimit(1)
        Spacer(minLength: 8)
      }
    }
    .buttonStyle(MenuRowStyle())
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}
