import DeviceKit
import Foundation
import SwiftUI

/// A location hidden from Finder, because its device is away, that still holds changes for the
/// device. Finder shows pending files only in a location it shows, so the menu names it.
struct WaitingChangesRow: View {
  let names: [String]

  var body: some View {
    ForEach(names, id: \.self) { name in
      let line = Self.line(name)
      StatusRow(symbol: "arrow.up.circle", title: Text(verbatim: line.text), help: line.help)
    }
  }

  /// What the row says, with its entry in Help. A device chooses its own name, so it is escaped.
  static func line(_ name: String) -> MenuNotice {
    MenuNotice(
      LocalizedStringResource(
        "\(DisplayText.escaped(name)): changes wait to be sent. Reconnect it to finish.",
        bundle: .module))
  }
}
