// Composes the README's images from the app's own views, drawn offscreen by the snapshot tests.
//
//   scripts/readme-images.sh        (runs the tests, then this; run from the repository root)
//   swift Design/README/render.swift <snapshots>
//
// <snapshots> holds what MenuSnapshotTests and HelpSnapshotTests write (menu-light.png,
// menu-dark.png, help-topic-light.png, help-topic-dark.png). Writes into Design/README:
//   hero-{light,dark}.png      the icon, the name and the menu
//   menu-{light,dark}.png      the menu with a tester open, a phone on Wi-Fi and a tablet
//   details-{light,dark}.png   the open tester's details, cropped from the menu
//   help-{light,dark}.png      a Help topic
//   finder-{light,dark}.png    an illustration of a Ferry location in Finder (drawn here, and
//                              labelled as an illustration: Finder cannot be drawn offscreen)
// Every address and serial in them is a documentation value (192.0.2.x, RFC 5737).

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appending(path: "Design/README")
guard CommandLine.arguments.count == 2,
  FileManager.default.fileExists(atPath: out.path)
else {
  FileHandle.standardError.write(Data("usage (from the repository root): swift Design/README/render.swift <snapshots>\n".utf8))
  exit(2)
}
let snapshots = URL(filePath: CommandLine.arguments[1])

func load(_ url: URL) -> NSBitmapImageRep {
  guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write(Data("Cannot read \(url.path)\n".utf8))
    exit(1)
  }
  rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
  return rep
}

func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: width, height: height)
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
  draw(context.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
  try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: name))
}

func text(
  _ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
  color: NSColor
) {
  (string as NSString).draw(
    at: point,
    withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

/// A screenshot in a window-like frame: rounded corners, a hairline and a soft shadow.
func framed(_ rep: NSImageRep, in rect: CGRect, radius: CGFloat, dark: Bool) {
  let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowBlurRadius = 40
  shadow.shadowOffset = CGSize(width: 0, height: -16)
  shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.25)
  shadow.set()
  NSColor.windowBackgroundColor.setFill()
  (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
  shape.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGraphicsContext.saveGraphicsState()
  shape.addClip()
  rep.draw(in: rect)
  NSGraphicsContext.restoreGraphicsState()
  (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
  shape.lineWidth = 2
  shape.stroke()
}

/// The part of `rep` in `rect`, measured from its top left.
func crop(_ rep: NSBitmapImageRep, _ rect: CGRect) -> NSBitmapImageRep {
  canvas(Int(rect.width), Int(rect.height)) { _ in
    rep.draw(
      in: CGRect(origin: .zero, size: rect.size),
      from: CGRect(
        x: rect.minX, y: CGFloat(rep.pixelsHigh) - rect.maxY, width: rect.width,
        height: rect.height), operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
  }
}

let icon = load(root.appending(path: "Design/Icon/Ferry.png"))

for dark in [false, true] {
  let suffix = dark ? "dark" : "light"
  let menu = load(snapshots.appending(path: "menu-\(suffix).png"))
  let help = load(snapshots.appending(path: "help-topic-\(suffix).png"))

  // Hero: icon, name and line on the left, the menu on the right, on the icon's water.
  let hero = canvas(2400, 1200) { cg in
    let colors =
      dark
      ? [NSColor(srgbRed: 0.04, green: 0.10, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.31, blue: 0.36, alpha: 1)]
      : [NSColor(srgbRed: 0.93, green: 0.96, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.82, green: 0.92, blue: 0.95, alpha: 1)]
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray,
      locations: nil)!
    cg.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: 1200), end: CGPoint(x: 0, y: 0), options: [])
    let wave = NSBezierPath()
    wave.move(to: CGPoint(x: 0, y: 230))
    wave.curve(
      to: CGPoint(x: 2400, y: 230), controlPoint1: CGPoint(x: 800, y: 330),
      controlPoint2: CGPoint(x: 1600, y: 130))
    wave.line(to: CGPoint(x: 2400, y: 0))
    wave.line(to: CGPoint(x: 0, y: 0))
    wave.close()
    NSColor(white: dark ? 1 : 0.4, alpha: dark ? 0.06 : 0.07).setFill()
    wave.fill()
    // NSImageRep.draw(in:) copies pixels; composite, so the icon's corners stay clear.
    icon.draw(
      in: CGRect(x: 250, y: 560, width: 400, height: 400), from: .zero, operation: .sourceOver,
      fraction: 1, respectFlipped: false, hints: nil)
    let ink = dark ? NSColor.white : NSColor(white: 0.1, alpha: 1)
    text("Ferry", at: CGPoint(x: 272, y: 380), size: 150, weight: .bold, color: ink)
    text(
      "Android devices in Finder,", at: CGPoint(x: 278, y: 296), size: 60,
      color: ink.withAlphaComponent(0.75))
    text(
      "over USB and Wi-Fi.", at: CGPoint(x: 278, y: 218), size: 60,
      color: ink.withAlphaComponent(0.75))
    let height: CGFloat = 1060
    let width = height * CGFloat(menu.pixelsWide) / CGFloat(menu.pixelsHigh)
    framed(
      menu, in: CGRect(x: 2400 - 330 - width, y: 70, width: width, height: height), radius: 28,
      dark: dark)
  }
  write(hero, "hero-\(suffix).png")
  write(menu, "menu-\(suffix).png")
  write(help, "help-\(suffix).png")
  // The open tester: its row and the details it reports, at the menu's top.
  write(crop(menu, CGRect(x: 0, y: 112, width: menu.pixelsWide, height: 282)), "details-\(suffix).png")
}

// MARK: - Finder illustration

/// Finder's sidebar symbol for Ferry, compiled from the extension's catalog as the app is.
func locationSymbol() -> NSImage {
  let bundle = FileManager.default.temporaryDirectory.appending(path: "ferry-readme-symbol.bundle")
  let resources = bundle.appending(path: "Contents/Resources")
  try? FileManager.default.removeItem(at: bundle)
  try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  try! PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "io.github.krisarmstrong.ferry.readme-symbol"],
    format: .xml, options: 0
  ).write(to: bundle.appending(path: "Contents/Info.plist"))
  let actool = Process()
  actool.executableURL = URL(filePath: "/usr/bin/xcrun")
  actool.arguments = [
    "actool", root.appending(path: "Apps/FerryProvider/Assets.xcassets").path, "--compile",
    resources.path, "--platform", "macosx", "--minimum-deployment-target", "26.0",
    "--output-partial-info-plist", bundle.appending(path: "partial.plist").path,
  ]
  actool.standardOutput = FileHandle.nullDevice
  try! actool.run()
  actool.waitUntilExit()
  guard let compiled = Bundle(url: bundle),
    let image = NSImage(symbolName: "ferry.location", bundle: compiled, variableValue: 1)
  else {
    FileHandle.standardError.write(Data("actool did not compile ferry.location\n".utf8))
    exit(1)
  }
  return image
}

let location = locationSymbol()
let folder = NSWorkspace.shared.icon(for: .folder)

func tintedSymbol(_ image: NSImage, _ color: NSColor, size: CGFloat) -> NSImage {
  let symbol = image.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? image
  return NSImage(size: symbol.size, flipped: false) { rect in
    symbol.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    return true
  }
}

for dark in [false, true] {
  let suffix = dark ? "dark" : "light"
  let s: CGFloat = 2
  let finder = canvas(Int(900 * s), Int(520 * s)) { _ in
    let window = CGRect(x: 30 * s, y: 30 * s, width: 840 * s, height: 460 * s)
    let shape = NSBezierPath(roundedRect: window, xRadius: 16 * s, yRadius: 16 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = CGSize(width: 0, height: -8 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.25)
    shadow.set()
    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Sidebar.
    let sidebar = CGRect(x: window.minX, y: window.minY, width: 210 * s, height: window.height)
    (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
    sidebar.fill()
    let ink = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)
    let muted = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.5, alpha: 1)
    let accent = NSColor(srgbRed: 0.04, green: 0.5, blue: 1, alpha: 1)
    // Window controls.
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
      color.setFill()
      NSBezierPath(
        ovalIn: CGRect(
          x: window.minX + (20 + CGFloat(index) * 20) * s, y: window.maxY - 30 * s, width: 12 * s,
          height: 12 * s)
      ).fill()
    }
    var y = window.maxY - 74 * s
    func heading(_ title: String) {
      text(title, at: CGPoint(x: sidebar.minX + 18 * s, y: y), size: 11 * s, weight: .semibold, color: muted)
      y -= 30 * s
    }
    func item(_ title: String, symbol: NSImage, selected: Bool = false) {
      if selected {
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).setFill()
        NSBezierPath(
          roundedRect: CGRect(x: sidebar.minX + 10 * s, y: y - 6 * s, width: 190 * s, height: 28 * s),
          xRadius: 7 * s, yRadius: 7 * s
        ).fill()
      }
      let glyph = tintedSymbol(symbol, accent, size: 14 * s)
      glyph.draw(at: CGPoint(x: sidebar.minX + 22 * s, y: y + 8 * s - glyph.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
      text(title, at: CGPoint(x: sidebar.minX + 50 * s, y: y), size: 13 * s, color: ink)
      y -= 30 * s
    }
    func system(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil)! }
    heading("Favorites")
    item("Desktop", symbol: system("menubar.dock.rectangle"))
    item("Documents", symbol: system("doc"))
    item("Downloads", symbol: system("arrow.down.circle"))
    y -= 10 * s
    heading("Locations")
    item("EtherScope-nXG", symbol: location, selected: true)
    item("Galaxy S24", symbol: location)
    // Toolbar title and the device's folders.
    let content = CGRect(x: sidebar.maxX, y: window.minY, width: window.width - sidebar.width, height: window.height)
    text("EtherScope-nXG", at: CGPoint(x: content.minX + 24 * s, y: window.maxY - 38 * s), size: 15 * s, weight: .bold, color: ink)
    (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).setFill()
    CGRect(x: content.minX, y: window.maxY - 56 * s, width: content.width, height: 1 * s).fill()
    let names = ["Android", "DCIM", "Documents", "Download", "Movies", "Pictures", "Screenshots"]
    for (index, name) in names.enumerated() {
      let column = CGFloat(index % 4)
      let row = CGFloat(index / 4)
      let x = content.minX + 40 * s + column * 150 * s
      let top = window.maxY - 100 * s - row * 160 * s
      folder.draw(in: CGRect(x: x + 20 * s, y: top - 86 * s, width: 84 * s, height: 84 * s))
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * s), .foregroundColor: ink]
      let size = (name as NSString).size(withAttributes: attributes)
      (name as NSString).draw(at: CGPoint(x: x + 62 * s - size.width / 2, y: top - 112 * s), withAttributes: attributes)
    }
    text("Illustration", at: CGPoint(x: window.maxX - 110 * s, y: window.minY + 14 * s), size: 12 * s, weight: .medium, color: muted)
    NSGraphicsContext.restoreGraphicsState()
  }
  write(finder, "finder-\(suffix).png")
}
print("Wrote the README images into \(out.path)")
