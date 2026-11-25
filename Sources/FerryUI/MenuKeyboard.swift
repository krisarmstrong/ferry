import AppKit
import SwiftUI

/// What a key does in the menu (L7), after a Mac menu: the arrows move between rows, Return or
/// Space activates the focused row, and Escape (`onExitCommand`) closes the menu. A text field
/// keeps the keys it uses itself, and the network form closes on Escape before the menu does.
enum MenuKey: Equatable {
  case next
  case previous
  case activate

  init?(_ key: KeyEquivalent) {
    switch key {
    case .downArrow: self = .next
    case .upArrow: self = .previous
    case .return, .space: self = .activate
    default: return nil
    }
  }
}

extension View {
  /// The menu window's arrows and Escape. The arrows move the key focus as Tab does, so they
  /// reach every row Tab reaches.
  func menuKeyboard(dismiss: @escaping () -> Void) -> some View {
    onKeyPress(keys: [.downArrow, .upArrow]) { press in
      guard let window = NSApp.keyWindow else { return .ignored }
      switch MenuKey(press.key) {
      case .next?: window.selectNextKeyView(nil)
      case .previous?: window.selectPreviousKeyView(nil)
      default: return .ignored
      }
      return .handled
    }
    .onExitCommand(perform: dismiss)
  }

  /// A row the keys reach and activate. A button takes key focus only with Keyboard
  /// navigation on, so without it the row is made focusable itself, drawing its focus as its
  /// highlight (`MenuRowStyle`) rather than a ring.
  func menuRowKeys(_ action: @escaping () -> Void) -> some View {
    let buttonsTakeFocus = NSApplication.shared.isFullKeyboardAccessEnabled
    return
      self
      .focusable(!buttonsTakeFocus)
      .focusEffectDisabled(!buttonsTakeFocus)
      .onKeyPress(keys: [.return, .space]) { press in
        guard MenuKey(press.key) == .activate else { return .ignored }
        action()
        return .handled
      }
  }
}
