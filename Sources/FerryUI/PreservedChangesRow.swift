import DeviceKit
import Foundation
import SwiftUI

/// An eject removed a location that still had changes for the device; the system kept them.
struct PreservedChangesRow: View {
  let locations: [URL]
  let reveal: () -> Void

  var body: some View {
    ForEach(locations, id: \.self) { location in
      let line = Self.line(location)
      StatusRow(symbol: "doc.on.doc", title: Text(verbatim: line.text), help: line.help)
    }
    StatusAction(title: Text("Reveal in Finder", bundle: .module), action: reveal)
  }

  /// What the row says, with its entry in Help.
  static func line(_ location: URL) -> MenuNotice {
    MenuNotice(
      LocalizedStringResource("Unsent changes were saved to \(shown(location))", bundle: .module))
  }

  /// The path with the home folder as `~`. The folder can be named after a device, which
  /// chooses its own name, so it is escaped.
  private static func shown(_ location: URL) -> String {
    DisplayText.escaped((location.path as NSString).abbreviatingWithTildeInPath)
  }
}
