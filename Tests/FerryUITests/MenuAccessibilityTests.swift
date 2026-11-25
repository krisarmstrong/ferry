import AppKit
import SwiftUI
import Testing

@testable import FerryUI

/// L6, L7 and L8: what VoiceOver reads for a status row's severity, what the menu's keys do, and
/// that a long row wraps in the menu's width rather than being cut.
struct MenuAccessibilityTests {
  /// The symbol's colour is hidden from VoiceOver, so a warning or an error says so first.
  @Test func aRowsSeverityIsSpokenBeforeItsTitle() {
    #expect(StatusSeverity.warning.spoken("adb isn't running") == "Warning: adb isn't running")
    #expect(StatusSeverity.error.spoken("Cancelled.") == "Error: Cancelled.")
    #expect(StatusSeverity.neutral.spoken("Checking…") == "Checking…")
    #expect(StatusSeverity.done.spoken("Ferry is ready") == "Ferry is ready")
    #expect(StatusSeverity.warning.tint == .yellow)
    #expect(StatusSeverity.error.tint == .red)
    #expect(StatusSeverity.neutral.tint == nil)
  }

  /// Arrows move between the rows and Return or Space activates one; Escape is the menu's exit
  /// command, not a key the rows take.
  @Test func theMenusKeys() {
    #expect(MenuKey(.downArrow) == .next)
    #expect(MenuKey(.upArrow) == .previous)
    #expect(MenuKey(.return) == .activate)
    #expect(MenuKey(.space) == .activate)
    #expect(MenuKey(.escape) == nil)
    #expect(MenuKey(.tab) == nil)
    #expect(MenuKey(KeyEquivalent("a")) == nil)
  }

  private static let longTitle =
    "More Tools with USB Debugging for the LinkRunner 100G in the second rack, row four"

  @MainActor private static func height(of view: some View) -> CGFloat {
    let hosting = NSHostingView(rootView: view.frame(width: 320))
    return hosting.fittingSize.height
  }

  /// SwiftUI on macOS applies no Dynamic Type, so larger words come from longer text or a
  /// larger font: a row's title wraps onto more lines instead of being cut at one.
  @Test @MainActor func aLongRowTitleWraps() {
    let short = Self.height(of: MenuRow(title: Text(verbatim: "Help"), action: {}))
    let long = Self.height(of: MenuRow(title: Text(verbatim: Self.longTitle), action: {}))
    #expect(long > short * 1.5)
  }

  @Test @MainActor func aLongDeviceNameWraps() {
    let tile = DevicePresentation.Tile(glyph: .phone, isActive: false)
    let short = Self.height(
      of: ExpandingRowHeader(tile: tile, name: "Pixel", summary: "USB", isExpanded: false) {})
    let long = Self.height(
      of: ExpandingRowHeader(
        tile: tile, name: Self.longTitle, summary: Self.longTitle, isExpanded: false
      ) {})
    #expect(long > short * 1.5)
  }
}
