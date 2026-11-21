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

/// The Help link beside a problem in the menu: a question mark that opens the problem's entry in
/// Help. Nothing when the message has no entry, or outside the menu, which puts its model in the
/// environment.
struct HelpLinkButton: View {
  @Environment(AppModel.self) private var model: AppModel?
  @Environment(\.openWindow) private var openWindow
  let key: String?

  /// What VoiceOver reads for the link: "Help:" and the problem's words, each value as "…". A
  /// key is the problem's English text, whichever module's catalog holds it.
  static func label(forMessage key: String) -> String {
    let problem = Bundle.module.localizedString(forKey: key, value: key, table: nil)
    return String(
      localized: LocalizedStringResource(
        "Help: \(HelpMessage.wording(of: problem))", bundle: .module))
  }

  var body: some View {
    if let key, let model {
      Button {
        model.showHelp(forMessage: key)
        NSApp.activate()
        openWindow(id: HelpView.windowID)
      } label: {
        Image(systemName: "questionmark.circle")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help(Text("Help", bundle: .module))
      // Several problems can show at once: each link names its own (audit L5).
      .accessibilityLabel(Self.label(forMessage: key))
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
