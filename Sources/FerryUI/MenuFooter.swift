import AppKit
import SwiftUI

/// The rows at the foot of the menu: Open at Login, Check for Updates… (in a build that can
/// update itself; Update Ready — Restart Ferry once an update waits for the next quit), Help and
/// Quit Ferry. Updates always install by themselves. Ferry has no Settings
/// window. Remove Ferry… is in Help, beside Uninstall; holding Option turns Quit Ferry into it,
/// as a Mac menu shows an item's alternative, and it opens that Help topic, which confirms.
struct MenuFooter: View {
  static let openAtLoginResource = LocalizedStringResource("Open at Login", bundle: .module)
  static let checkForUpdatesResource = LocalizedStringResource(
    "Check for Updates…", bundle: .module)
  static let updateReadyResource = LocalizedStringResource(
    "Update Ready — Restart Ferry", bundle: .module)

  /// The line under Open at Login while macOS waits for the user to allow it.
  static func loginItemDetail(_ status: LoginItemStatus) -> LocalizedStringResource? {
    status == .needsApproval
      ? LocalizedStringResource("Needs approval in System Settings", bundle: .module) : nil
  }

  /// The last row's title: Remove Ferry… while Option is held.
  static func quitTitle(optionHeld: Bool) -> LocalizedStringResource {
    optionHeld
      ? LocalizedStringResource("Remove Ferry…", bundle: .module)
      : LocalizedStringResource("Quit Ferry", bundle: .module)
  }

  @Environment(\.openWindow) private var openWindow
  @State private var optionHeld = false
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Toggle(
        isOn: Binding(
          get: { model.opensAtLogin }, set: { model.requestOpensAtLogin($0) })
      ) {
        // In the label, so VoiceOver reads it with the switch.
        VStack(alignment: .leading, spacing: 1) {
          Text(Self.openAtLoginResource)
          if let detail = Self.loginItemDetail(model.loginItem) {
            Text(detail)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .toggleStyle(MenuToggleStyle())
      if model.updateReady {
        MenuRow(title: Text(Self.updateReadyResource)) {
          model.restartToUpdate()
        }
      } else if model.updater != nil {
        MenuRow(title: Text(Self.checkForUpdatesResource)) {
          model.checkForUpdates()
        }
      }
      MenuRow(title: Text("Help", bundle: .module), shortcut: "⌘?") {
        NSApp.activate()
        openWindow(id: HelpView.windowID)
      }
      .keyboardShortcut("?")
      if optionHeld {
        MenuRow(title: Text(Self.quitTitle(optionHeld: true))) {
          model.showRemoveFerry()
          NSApp.activate()
          openWindow(id: HelpView.windowID)
        }
      } else {
        MenuRow(title: Text(Self.quitTitle(optionHeld: false)), shortcut: "⌘Q") {
          NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
      }
    }
    .onModifierKeysChanged(mask: .option) { _, held in optionHeld = held.contains(.option) }
  }
}

/// A toggle drawn as a menu row: a checkmark on the trailing edge while it is on, where the other
/// rows show their shortcuts, so its title lines up with theirs. VoiceOver reads it as a switch
/// with its state.
struct MenuToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 8) {
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Image(systemName: "checkmark")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
          .opacity(configuration.isOn ? 1 : 0)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(MenuRowStyle())
    .menuRowKeys { configuration.isOn.toggle() }
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}
