import AppKit
import SwiftUI
import Testing

@testable import FerryUI

/// Draws the Help window offscreen: once searching, and once on the Troubleshooting topic a
/// Help link opened. Each must show something besides its background. Offscreen, the sidebar's
/// list and the search text do not draw; the detail and the toolbar do. With
/// `FERRY_HELP_SNAPSHOTS` naming a folder, the images are also written there as
/// `help-search.png` and `help-trouble.png`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HelpSnapshotTests {
  private static let size = CGSize(width: 900, height: 620)

  private func drawnWindow(query: String, message: String?) throws -> NSBitmapImageRep {
    let model = AppModel.preview([])
    if let message { model.showHelp(forMessage: message) }
    let controller = NSHostingController(
      rootView: HelpView(model: model, content: .bundled, query: query))
    let window = NSWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    window.title = "Ferry Help"
    window.appearance = NSAppearance(named: .aqua)
    window.setContentSize(Self.size)
    window.layoutIfNeeded()
    controller.view.layoutSubtreeIfNeeded()
    let frame = try #require(window.contentView?.superview)
    frame.layoutSubtreeIfNeeded()
    let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    frame.cacheDisplay(in: frame.bounds, to: bitmap)
    window.close()
    return bitmap
  }

  private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
    var colors = Set<String>()
    for row in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
      for column in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
        if let color = bitmap.colorAt(x: column, y: row) { colors.insert("\(color)") }
      }
    }
    return colors.count
  }

  private func save(_ bitmap: NSBitmapImageRep, as name: String) throws {
    guard let folder = ProcessInfo.processInfo.environment["FERRY_HELP_SNAPSHOTS"] else { return }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(filePath: folder).appending(path: name))
  }

  @Test func theSearchDraws() throws {
    let bitmap = try drawnWindow(query: "recording", message: nil)
    #expect(distinctColors(bitmap) > 10)
    try save(bitmap, as: "help-search.png")
  }

  @Test func aTroubleshootingTopicDraws() throws {
    let bitmap = try drawnWindow(query: "", message: "The device was disconnected.")
    #expect(distinctColors(bitmap) > 10)
    try save(bitmap, as: "help-trouble.png")
  }
}
