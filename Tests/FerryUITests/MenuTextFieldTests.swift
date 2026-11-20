import AppKit
import DeviceKit
import SwiftUI
import Testing

@testable import FerryUI

/// The network forms' fields, hosted in a window as the menu's panel hosts them: the first
/// field takes focus when the form opens, typing reaches the model, and Escape closes the form.
/// Whether the menu-bar panel itself becomes key on a click is only seen in live use. One
/// window at a time: each must be the key window for its keys and focus.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MenuTextFieldTests {
  private func hosted(_ model: AppModel) -> NSWindow {
    hosted(NetworkFormRows(model: model))
  }

  private func hosted(_ rows: some View) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 320), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: VStack(spacing: 0) { rows }.frame(width: 320))
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

  private func escape(in window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
  }

  /// Escape still reaches the form while it sends, and cancels the send.
  @Test func escapeCancelsASendInFlight() async throws {
    let log = CallLog()
    let client = FakeClient(log: log)
    client.wirelessPark.start()
    let model = AppModel(client: client, services: FakeServices(log: log))
    model.toggleNetworkForm(.address)
    let window = hosted(model)
    defer { window.close() }
    let content = try #require(window.contentView)
    let field = try #require(textFields(in: content).first)
    settle()
    try type("192.0.2.31", into: field, of: window)
    let send = Task { await model.submitNetworkForm() }
    for await _ in client.wirelessPark.arrivals { break }
    settle()
    #expect(model.networkForm?.isSending == true)
    window.sendEvent(try escape(in: window))
    let closedByEscape = model.networkForm == nil
    // Ends the send either way, so a failure here is reported rather than left waiting.
    if !closedByEscape { model.closeNetworkForm() }
    await send.value
    #expect(closedByEscape)
    #expect(log.all.contains("wireless cancelled"))
  }

  /// A failed send leaves the field focused, so the address can be corrected at once.
  @Test func aFailedSendKeepsTheFieldFocused() async throws {
    let log = CallLog()
    let client = FakeClient(log: log)
    client.setWireless(.wireless(.failed(.otherDevice)))
    let model = AppModel(client: client, services: FakeServices(log: log))
    model.toggleNetworkForm(.address)
    let window = hosted(model)
    defer { window.close() }
    let content = try #require(window.contentView)
    let field = try #require(textFields(in: content).first)
    settle()
    try type("192.0.2.31", into: field, of: window)
    await model.submitNetworkForm()
    settle()
    #expect(model.networkForm?.address == "192.0.2.31")
    #expect(field.currentEditor() != nil)
    #expect(window.firstResponder === field.currentEditor())
  }

  /// Port Forwarding's fields start empty, showing their prompts, and take typing.
  @Test func thePortFieldsTakeTyping() async throws {
    let log = CallLog()
    let client = FakeClient(log: log)
    let id = DeviceID(serial: "ES1")
    client.setStatus([device(id.serial, model: "EtherScope-nXG", .ready([]), method: .usbADB)])
    let model = AppModel(client: client, services: FakeServices(log: log))
    await model.refresh()
    model.toggleExpansion(.device(id))
    await model.toggleForwards(of: id)
    let session = try #require(model.openForwards(of: id))
    let window = hosted(PortForwardRows(tools: ToolActions(model: model, device: id) {}))
    defer { window.close() }
    let content = try #require(window.contentView)
    let fields = textFields(in: content)
    #expect(fields.count == 2)
    let (local, remote) = (try #require(fields.first), try #require(fields.last))
    #expect(local.stringValue.isEmpty && remote.stringValue.isEmpty)
    #expect(
      local.placeholderString == "8080" || local.placeholderAttributedString?.string == "8080")

    try type("8080", into: local, of: window)
    try type("80", into: remote, of: window)
    #expect(session.localPort == "8080")
    #expect(session.remotePort == "80")
  }
}
