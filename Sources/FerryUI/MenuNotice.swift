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

extension EnvironmentValues {
  /// Opens Help on the entry for a message's catalog key. The menu sets it; a view without it
  /// shows no Help link.
  @Entry var openHelp: (@MainActor (String) -> Void)?
}

/// The Help link beside a problem in the menu: a question mark that opens the problem's entry in
/// Help. Nothing when the message has no entry or the menu gives no way to open Help.
struct HelpLinkButton: View {
  @Environment(\.openHelp) private var openHelp
  let key: String?

  var body: some View {
    if let key, let openHelp {
      Button {
        openHelp(key)
      } label: {
        Image(systemName: "questionmark.circle")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help(Text("Help", bundle: .module))
      .accessibilityLabel(Text("Help", bundle: .module))
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
