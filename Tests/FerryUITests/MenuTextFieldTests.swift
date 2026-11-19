import AppKit
import DeviceKit
import SwiftUI
import Testing

@testable import FerryUI

/// The network forms' fields, hosted in a window as the menu's panel hosts them: the first
/// field takes focus when the form opens, typing reaches the model, and Escape closes the form.
/// Whether the menu-bar panel itself becomes key on a click is only seen in live use.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MenuTextFieldTests {
  private func hosted(_ model: AppModel) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 320), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: VStack(spacing: 0) { NetworkFormRows(model: model) }.frame(width: 320))
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      if let field = subview as? NSTextField, field.isEditable { return [field] }
      return textFields(in: subview)
    }
  }

  private func type(_ text: String, into field: NSTextField, of window: NSWindow) throws {
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  /// Lets the window handle what is queued for it (focus set on appear), without waiting.
  private func settle() {
    for _ in 0..<5 { RunLoop.main.run(mode: .default, before: .distantPast) }
  }

  @Test func pairWithCodeTakesFocusAndTypingAndEscapeClosesIt() throws {
    let model = AppModel(client: FakeClient(log: CallLog()), services: FakeServices(log: CallLog()))
    model.toggleNetworkForm(.code)
    let window = hosted(model)
    defer { window.close() }
    let fields = textFields(in: try #require(window.contentView))
    #expect(fields.count == 2)
    let (address, code) = (try #require(fields.first), try #require(fields.last))
    settle()
    // The form opened with its address field focused.
    #expect(address.currentEditor() != nil)
    #expect(window.firstResponder === address.currentEditor())

    try type("192.0.2.31:37123", into: address, of: window)
    try type("482913", into: code, of: window)
    #expect(model.networkForm?.address == "192.0.2.31:37123")
    #expect(model.networkForm?.code == "482913")
    #expect(model.networkForm?.canSend == true)

    let escape = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    window.sendEvent(escape)
    #expect(model.networkForm == nil)
  }
}
