import AppKit
import SwiftUI

/// A message the menu shows, with the catalog key Help explains it by. It can carry text a
/// device or adb wrote, so it is shown verbatim, never parsed as Markdown.
public struct MenuNotice: Equatable, Sendable {
  public let text: String
  /// The message's catalog key, which opens its entry in Help; `nil` when Help has none.
  public let help: String?

  init(text: String, help: String?) {
    self.text = text
    self.help = help
  }

  /// The message `resource` words, explained in Help under its key.
  init(_ resource: LocalizedStringResource) {
    self.init(text: String(localized: resource), help: resource.key)
  }
}

/// The Help link beside a problem in the menu, or a step of the welcome: a question mark that
/// opens the problem's entry, or the step's topic, in Help. Nothing when the message has no
/// entry, or outside a view that puts its model in the environment.
struct HelpLinkButton: View {
  @Environment(AppModel.self) private var model: AppModel?
  @Environment(\.openWindow) private var openWindow
  let request: HelpRequest?

  init(key: String?) {
    request = key.map(HelpRequest.message)
  }

  init(topic id: String) {
    request = .topic(id)
  }

  /// What VoiceOver reads for the link: "Help:" and the problem's words, each value as "…". A
  /// key is the problem's English text, whichever module's catalog holds it.
  static func label(forMessage key: String) -> String {
    let problem = Bundle.module.localizedString(forKey: key, value: key, table: nil)
    return String(
      localized: LocalizedStringResource(
        "Help: \(HelpMessage.wording(of: problem))", bundle: .module))
  }

  /// What VoiceOver reads for a topic's link: "Help:" and the topic's title.
  static func label(forTopic id: String) -> String {
    let title = HelpContent.bundled?.topics.first { $0.id == id }.map { HelpText.plain($0.title) }
    return String(localized: LocalizedStringResource("Help: \(title ?? id)", bundle: .module))
  }

  var body: some View {
    if let request, let model {
      Button {
        switch request {
        case .message(let key): model.showHelp(forMessage: key)
        case .topic(let id): model.showHelp(topic: id)
        }
        NSApp.activate()
        openWindow(id: HelpView.windowID)
      } label: {
        Image(systemName: "questionmark.circle")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help(Text("Help", bundle: .module))
      // Several problems can show at once: each link names its own (audit L5).
      .accessibilityLabel(label(request))
    }
  }

  private func label(_ request: HelpRequest) -> String {
    switch request {
    case .message(let key): Self.label(forMessage: key)
    case .topic(let id): Self.label(forTopic: id)
    }
  }
}

/// A line that reports a problem, with its Help link after it.
struct HelpLinked<Content: View>: View {
  let key: String?
  @ViewBuilder let content: Content

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      content
        .fixedSize(horizontal: false, vertical: true)
      HelpLinkButton(key: key)
    }
  }
}
