// Renders the DMG window's background from Design/DMG/background.svg.
//
//   swift Design/DMG/render.swift        (run from the repository root)
//
// Writes:
//   Design/DMG/background.tiff        640 x 400 pt at 1x and 2x, which scripts/make-dmg.sh uses
//   Design/previews/dmg-window.png    the window as Finder lays it out, in light and dark
//
// The preview places the icons where scripts/dmg-settings.py puts them, with Finder's label
// colors: black in light mode, white in dark mode.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dmgDir = root.appending(path: "Design/DMG")
let previewsDir = root.appending(path: "Design/previews")
guard let background = NSImage(contentsOf: dmgDir.appending(path: "background.svg")) else {
  FileHandle.standardError.write(Data("Run from the repository root.\n".utf8))
  exit(1)
}
try! FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)

let window = CGSize(width: 640, height: 400)

func bitmap(_ width: Int, _ height: Int, _ draw: () -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: width, height: height)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  draw()
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

/// The background at `scale`, its size in points recorded so the TIFF carries both resolutions.
func backgroundRep(scale: Int) -> NSBitmapImageRep {
  let rep = bitmap(Int(window.width) * scale, Int(window.height) * scale) {
    background.draw(in: CGRect(x: 0, y: 0, width: window.width * CGFloat(scale),
      height: window.height * CGFloat(scale)))
  }
  rep.size = window
  return rep
}

let reps = [backgroundRep(scale: 1), backgroundRep(scale: 2)]
let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0)!
try! tiff.write(to: dmgDir.appending(path: "background.tiff"))

// The window as Finder shows it, at 2x: title bar, background, the two icons and their labels.
let icon = NSImage(contentsOf: root.appending(path: "Design/Icon/Ferry.png"))!
let applications = NSWorkspace.shared.icon(forFile: "/Applications")
let titleBar: CGFloat = 28
let scale: CGFloat = 2
let panelWidth = Int((window.width + 80) * scale)
let panelHeight = Int((window.height + titleBar + 80) * scale)
let sheet = bitmap(panelWidth * 2, panelHeight) {
  for (index, dark) in [false, true].enumerated() {
    let origin = CGPoint(x: CGFloat(panelWidth * index), y: 0)
    (dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
    CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight)).fill()
    let frame = CGRect(
      x: origin.x + 40 * scale, y: 40 * scale, width: window.width * scale,
      height: (window.height + titleBar) * scale)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 12 * scale, yRadius: 12 * scale)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = CGSize(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let content = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: window.height * scale)
    background.draw(in: content)
    let title: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13 * scale, weight: .semibold),
      .foregroundColor: dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.2, alpha: 1),
    ]
    let name = "Ferry" as NSString
    let titleSize = name.size(withAttributes: title)
    name.draw(
      at: CGPoint(x: frame.midX - titleSize.width / 2, y: content.maxY + (titleBar * scale - titleSize.height) / 2),
      withAttributes: title)
    // Icon centres in Finder's top-left coordinates (scripts/dmg-settings.py).
    for (image, label, centre) in [
      (icon, "Ferry", CGPoint(x: 170, y: 180)), (applications, "Applications", CGPoint(x: 470, y: 180)),
    ] {
      let side: CGFloat = 128 * scale
      let x = content.minX + centre.x * scale - side / 2
      let y = content.maxY - centre.y * scale - side / 2
      image.draw(in: CGRect(x: x, y: y, width: side, height: side))
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13 * scale), .foregroundColor: dark ? NSColor.white : NSColor.black,
      ]
      let text = label as NSString
      let size = text.size(withAttributes: attributes)
      text.draw(at: CGPoint(x: x + side / 2 - size.width / 2, y: y - size.height - 4 * scale), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}
try! sheet.representation(using: .png, properties: [:])!.write(
  to: previewsDir.appending(path: "dmg-window.png"))
print("Rendered \(dmgDir.path)/background.tiff and the preview")
