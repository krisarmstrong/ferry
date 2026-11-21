// Renders Ferry's icon assets from the SVG sources in Design/Icon.
//
//   swift Design/Icon/scripts/render.swift        (run from the repository root)
//
// Writes:
//   Design/Icon/Ferry.icon/Assets/*.svg             copies of the layers Icon Composer uses
//   Design/Icon/AppIcon.appiconset/*.png            classic icon, squircle and shadow drawn here
//   Design/Icon/MenuBarGlyph-{16,18,22}{,@2x}.png   template images (black + alpha)
//   Apps/Ferry/Assets.xcassets/MenuBarGlyph.imageset/MenuBarGlyph.svg   the 18 pt glyph
//   Design/Icon/Ferry.png                           512 px icon for the README, as macOS draws it
//   Design/previews/icon-appearances.png            Ferry.icon as macOS draws it, every appearance
//   Design/previews/icon-sizes.png                  classic sizes on light and dark, 8x zooms
//   Design/previews/menubar-glyph.png               the menu bar glyph at 16, 18 and 22 pt
//   Design/previews/finder-location-symbol.png      the Finder sidebar symbol beside Finder's own
//
// The appearances come from Icon Composer's own renderer (ictool, inside Xcode); everything
// else uses only AppKit (NSImage reads SVG through CoreSVG).

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = root.appending(path: "Design/Icon")
let layersDir = iconDir.appending(path: "layers")
let previewsDir = root.appending(path: "Design/previews")
guard FileManager.default.fileExists(atPath: layersDir.path) else {
  FileHandle.standardError.write(Data("Run from the repository root.\n".utf8))
  exit(1)
}
try! FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)

func load(_ url: URL) -> NSImage {
  guard let image = NSImage(contentsOf: url) else {
    FileHandle.standardError.write(Data("Cannot load \(url.path)\n".utf8))
    exit(1)
  }
  return image
}

func svg(_ name: String) -> NSImage { load(layersDir.appending(path: "\(name).svg")) }

let background = svg("background")
let water = svg("water")
let wave = svg("wave")
let hull = svg("hull")
let cargo = svg("cargo")
let smallHull = svg("hull-small")
let smallCargo = svg("cargo-small")
let hull16 = svg("hull-16")
let cargo16 = svg("cargo-16")
let glyphSizes = [16, 18, 22]
let glyphs = Dictionary(
  uniqueKeysWithValues: glyphSizes.map {
    ($0, load(iconDir.appending(path: "MenuBarGlyph-\($0).svg")))
  })

/// A bitmap with exactly `width` x `height` pixels, drawn at 1 point per pixel.
func bitmap(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: width, height: height)
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
  draw(context.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

func write(_ rep: NSBitmapImageRep, _ url: URL) {
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Composites `rep` into `rect` of the current context, keeping its transparency.
func composite(_ rep: NSImageRep, in rect: CGRect) {
  rep.draw(
    in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
}

/// Apple's continuous-corner app shape, approximated by a superellipse (n = 5).
func squircle(in rect: CGRect) -> CGPath {
  let path = CGMutablePath()
  let n = 5.0
  let a = rect.width / 2
  let b = rect.height / 2
  for step in 0...720 {
    let t = Double(step) / 720 * 2 * .pi
    let c = cos(t)
    let s = sin(t)
    let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
    let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
    if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
  }
  path.closeSubpath()
  return path
}

/// The classic macOS icon at `px` pixels: an 824/1024 squircle with a soft shadow, the layers
/// clipped inside it. Sizes of 32 px and below use the simplified small-size glyph.
func classicIcon(_ px: Int) -> NSBitmapImageRep {
  bitmap(px, px) { cg in
    let scale = CGFloat(px) / 1024
    // Small sizes snap the tile to whole pixels (14 px inset 1 at 16, 26 px inset 3 at 32), and
    // their glyph layers are drawn on that pixel grid.
    let inset = px <= 32 ? (100 * scale).rounded(.down) : 100 * scale
    let side = px <= 32 ? CGFloat(px) - 2 * inset : 824 * scale
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = squircle(in: tile)
    cg.saveGState()
    cg.setShadow(
      offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor(srgbRed: 0.08, green: 0.36, blue: 0.6, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    // At 16 px the water edge only smears behind the hull, so it is left out there.
    let layers =
      px <= 16
      ? [background, cargo16, hull16]
      : px <= 32
        ? [background, water, smallCargo, smallHull]
        : [background, water, cargo, hull, wave]
    for layer in layers {
      layer.draw(in: tile)
    }
    cg.restoreGState()
  }
}

/// Black + alpha only, so macOS can tint it for the menu bar.
func templateGlyph(_ points: Int, scale: Int) -> NSBitmapImageRep {
  let px = points * scale
  return bitmap(px, px) { _ in glyphs[points]!.draw(in: CGRect(x: 0, y: 0, width: px, height: px)) }
}

// Icon Composer bundle: the layers are the source of truth, so copy them in.
let iconBundle = iconDir.appending(path: "Ferry.icon")
let iconAssets = iconBundle.appending(path: "Assets")
try? FileManager.default.removeItem(at: iconAssets)
try! FileManager.default.createDirectory(at: iconAssets, withIntermediateDirectories: true)
for name in ["water", "wave", "hull", "cargo"] {
  try! FileManager.default.copyItem(
    at: layersDir.appending(path: "\(name).svg"), to: iconAssets.appending(path: "\(name).svg"))
}

// Classic app icon set.
let appIconSet = iconDir.appending(path: "AppIcon.appiconset")
try! FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
  for factor in [1, 2] {
    let suffix = factor == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    write(classicIcon(points * factor), appIconSet.appending(path: name))
    images.append([
      "filename": name, "idiom": "mac", "scale": "\(factor)x", "size": "\(points)x\(points)",
    ])
  }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: appIconSet.appending(path: "Contents.json"))

for points in glyphSizes {
  write(templateGlyph(points, scale: 1), iconDir.appending(path: "MenuBarGlyph-\(points).png"))
  write(templateGlyph(points, scale: 2), iconDir.appending(path: "MenuBarGlyph-\(points)@2x.png"))
}
// The app's status item draws the 18 pt glyph as a vector template.
let imageset = root.appending(path: "Apps/Ferry/Assets.xcassets/MenuBarGlyph.imageset/MenuBarGlyph.svg")
try? FileManager.default.removeItem(at: imageset)
try! FileManager.default.copyItem(at: iconDir.appending(path: "MenuBarGlyph-18.svg"), to: imageset)

// MARK: - Previews

let ink = NSColor(white: 0.1, alpha: 1)
let paper = NSColor(white: 0.96, alpha: 1)
let night = NSColor(white: 0.12, alpha: 1)

func label(_ text: String, _ x: CGFloat, _ y: CGFloat, color: NSColor, size: CGFloat = 28) {
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
  ]
  (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
}

/// Ferry.icon drawn by Icon Composer's renderer, in one appearance.
func rendition(_ name: String, tint: Double? = nil) -> NSBitmapImageRep {
  let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? "/Applications/Xcode.app/Contents/Developer"
  let tool = URL(filePath: developer).deletingLastPathComponent()
    .appending(path: "Applications/Icon Composer.app/Contents/Executables/ictool")
  let output = FileManager.default.temporaryDirectory.appending(path: "ferry-\(name).png")
  let process = Process()
  process.executableURL = tool
  var arguments = [
    iconBundle.path, "--export-image", "--output-file", output.path, "--platform", "macOS",
    "--rendition", name, "--width", "512", "--height", "512", "--scale", "1",
  ]
  if let tint { arguments += ["--tint-color", "\(tint)", "--tint-strength", "0.8"] }
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  try! process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0, let data = try? Data(contentsOf: output),
    let rep = NSBitmapImageRep(data: data)
  else {
    FileHandle.standardError.write(Data("ictool could not render \(name)\n".utf8))
    exit(1)
  }
  return rep
}

// Every appearance macOS 26 offers, each on the backdrop it is shown against.
let appearances: [(String, String, Double?, Bool)] = [
  ("Default", "Default", nil, false), ("Dark", "Dark", nil, true),
  ("TintedLight", "Tinted (light)", 0.58, false), ("TintedDark", "Tinted (dark)", 0.58, true),
  ("ClearLight", "Clear (light)", nil, false), ("ClearDark", "Clear (dark)", nil, true),
]
let cell = 620
let appearanceSheet = bitmap(cell * 3, cell * 2) { cg in
  for (index, (name, title, tint, dark)) in appearances.enumerated() {
    let x = CGFloat(index / 2 * cell)
    let y = CGFloat((1 - index % 2) * cell)
    let backdrop = CGRect(x: x, y: y, width: CGFloat(cell), height: CGFloat(cell))
    if name.hasPrefix("Clear") {
      // Clear icons are meant to be seen over a picture: a soft wallpaper-like gradient.
      let colors =
        dark
        ? [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.22, alpha: 1).cgColor,
          NSColor(srgbRed: 0.28, green: 0.14, blue: 0.30, alpha: 1).cgColor]
        : [NSColor(srgbRed: 0.98, green: 0.80, blue: 0.62, alpha: 1).cgColor,
          NSColor(srgbRed: 0.62, green: 0.78, blue: 0.96, alpha: 1).cgColor]
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
      cg.saveGState()
      cg.clip(to: backdrop)
      cg.drawLinearGradient(
        gradient, start: backdrop.origin, end: CGPoint(x: backdrop.maxX, y: backdrop.maxY),
        options: [])
      cg.restoreGState()
    } else {
      cg.setFillColor((dark ? night : paper).cgColor)
      cg.fill(backdrop)
    }
    composite(rendition(name, tint: tint), in: CGRect(x: x + 54, y: y + 70, width: 512, height: 512))
    label(title, x + 30, y + 24, color: dark ? paper : ink)
  }
}
write(appearanceSheet, previewsDir.appending(path: "icon-appearances.png"))
// The README shows the icon as macOS draws it.
write(rendition("Default"), iconDir.appending(path: "Ferry.png"))

func nearestNeighbour(_ rep: NSBitmapImageRep, _ factor: Int) -> NSImage {
  let image = NSImage(size: NSSize(width: rep.pixelsWide * factor, height: rep.pixelsHigh * factor))
  image.addRepresentation(rep)
  return image
}

// Classic sizes, bottoms aligned, then 8x nearest-neighbour zooms of the small renders.
let sheetWidth = 2600
let panelHeight = 1240
let sizesSheet = bitmap(sheetWidth, panelHeight * 2) { cg in
  for (index, (name, fill, text)) in [("Light", paper, ink), ("Dark", night, paper)].enumerated() {
    let originY = CGFloat(panelHeight * (1 - index))
    cg.setFillColor(fill.cgColor)
    cg.fill(CGRect(x: 0, y: originY, width: CGFloat(sheetWidth), height: CGFloat(panelHeight)))
    label(name, 40, originY + CGFloat(panelHeight) - 60, color: text)
    var x: CGFloat = 40
    let base: CGFloat = 120
    for px in [1024, 512, 128, 32, 16] {
      composite(classicIcon(px), in: CGRect(x: x, y: originY + base, width: CGFloat(px), height: CGFloat(px)))
      label("\(px)", x, originY + base - 50, color: text)
      x += CGFloat(px) + 40
    }
    var zoomX: CGFloat = 1960
    for px in [16, 32] {
      NSGraphicsContext.current?.imageInterpolation = .none
      nearestNeighbour(classicIcon(px), 8).draw(
        in: CGRect(x: zoomX, y: originY + base, width: CGFloat(px * 8), height: CGFloat(px * 8)))
      NSGraphicsContext.current?.imageInterpolation = .high
      label("\(px) px x8", zoomX, originY + base - 50, color: text)
      zoomX += CGFloat(px * 8) + 40
    }
  }
}
write(sizesSheet, previewsDir.appending(path: "icon-sizes.png"))

/// A template image tinted the way macOS tints the menu bar.
func tinted(_ rep: NSBitmapImageRep, _ tint: NSColor) -> NSImage {
  let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
  image.lockFocus()
  rep.draw(in: NSRect(origin: .zero, size: image.size))
  tint.set()
  NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
  image.unlockFocus()
  return image
}

// The glyph in a menu bar at 2x (as on every current Mac), then each size's pixels at 1x and 2x.
let glyphSheet = bitmap(1400, 1000) { cg in
  for (index, (fill, tint)) in [
    (NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white),
  ].enumerated() {
    let originY = CGFloat(500 * (1 - index))
    cg.setFillColor(fill.cgColor)
    cg.fill(CGRect(x: 0, y: originY, width: 1400, height: 500))
    let bar = CGRect(x: 40, y: originY + 400, width: 1320, height: 48)
    cg.setFillColor(fill.blended(withFraction: 0.08, of: tint)!.cgColor)
    cg.fill(bar)
    // Neighbours for scale: system symbols at the menu bar's size, then Ferry's glyph.
    var x = bar.minX + 24
    for name in ["wifi", "battery.75percent", "magnifyingglass"] {
      let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))!
      let image = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        return true
      }
      image.draw(at: CGPoint(x: x, y: bar.midY - symbol.size.height / 2), from: .zero,
        operation: .sourceOver, fraction: 1)
      x += symbol.size.width + 32
    }
    tinted(templateGlyph(18, scale: 2), tint).draw(
      in: CGRect(x: x, y: bar.midY - 18, width: 36, height: 36))
    label("menu bar at 2x: Wi-Fi, battery, Spotlight, Ferry", bar.minX, bar.minY - 44, color: tint,
      size: 22)
    // Each size: 1x at 8x zoom, 2x at 4x zoom.
    var zoomX: CGFloat = 40
    for points in glyphSizes {
      NSGraphicsContext.current?.imageInterpolation = .none
      let side = CGFloat(points * 8)
      tinted(templateGlyph(points, scale: 1), tint).draw(
        in: CGRect(x: zoomX, y: originY + 70, width: side, height: side))
      tinted(templateGlyph(points, scale: 2), tint).draw(
        in: CGRect(x: zoomX + side + 20, y: originY + 70, width: side, height: side))
      NSGraphicsContext.current?.imageInterpolation = .high
      label("\(points) pt: 1x | 2x", zoomX, originY + 24, color: tint, size: 22)
      zoomX += side * 2 + 70
    }
  }
}
write(glyphSheet, previewsDir.appending(path: "menubar-glyph.png"))

// The Finder location symbol (scripts/location-symbol.py), compiled by actool as the
// extension's catalog is, beside Finder's own sidebar symbols at the sidebar's sizes.
let symbolBundle = FileManager.default.temporaryDirectory.appending(path: "ferry-symbol.bundle")
let symbolResources = symbolBundle.appending(path: "Contents/Resources")
try? FileManager.default.removeItem(at: symbolBundle)
try! FileManager.default.createDirectory(at: symbolResources, withIntermediateDirectories: true)
try! PropertyListSerialization.data(
  fromPropertyList: ["CFBundleIdentifier": "io.github.krisarmstrong.ferry.symbol-preview"],
  format: .xml, options: 0
).write(to: symbolBundle.appending(path: "Contents/Info.plist"))
let actool = Process()
actool.executableURL = URL(filePath: "/usr/bin/xcrun")
actool.arguments = [
  "actool", root.appending(path: "Apps/FerryProvider/Assets.xcassets").path, "--compile",
  symbolResources.path, "--platform", "macosx", "--minimum-deployment-target", "26.0",
  "--output-partial-info-plist", symbolBundle.appending(path: "partial.plist").path,
]
actool.standardOutput = FileHandle.nullDevice
try! actool.run()
actool.waitUntilExit()
guard actool.terminationStatus == 0, let compiled = Bundle(url: symbolBundle),
  let location = NSImage(symbolName: "ferry.location", bundle: compiled, variableValue: 1)
else {
  FileHandle.standardError.write(Data("actool did not compile ferry.location\n".utf8))
  exit(1)
}
let symbolSheet = bitmap(1200, 560) { cg in
  for (index, (fill, tint)) in [
    (NSColor(white: 0.95, alpha: 1), NSColor(srgbRed: 0.0, green: 0.48, blue: 1, alpha: 1)),
    (NSColor(white: 0.17, alpha: 1), NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)),
  ].enumerated() {
    let originY = CGFloat(280 * (1 - index))
    cg.setFillColor(fill.cgColor)
    cg.fill(CGRect(x: 0, y: originY, width: 1200, height: 280))
    let text = index == 0 ? ink : paper
    var x: CGFloat = 40
    // Sidebar rows at 2x: Finder's symbols for iCloud Drive and an external disk, then Ferry.
    for (image, name) in [
      (NSImage(systemSymbolName: "icloud", accessibilityDescription: nil)!, "iCloud Drive"),
      (NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)!, "Backup"),
      (location, "EtherScope-nXG"),
    ] {
      for (row, weight) in [(0, NSFont.Weight.regular), (1, .semibold)] {
        let symbol = image.withSymbolConfiguration(.init(pointSize: 30, weight: weight))!
        let tintedSymbol = NSImage(size: symbol.size, flipped: false) { rect in
          symbol.draw(in: rect)
          tint.set()
          rect.fill(using: .sourceAtop)
          return true
        }
        let y = originY + 180 - CGFloat(row) * 90
        tintedSymbol.draw(at: CGPoint(x: x, y: y - symbol.size.height / 2), from: .zero,
          operation: .sourceOver, fraction: 1)
        label(name, x + 56, y - 16, color: text, size: 26)
      }
      x += 380
    }
  }
}
write(symbolSheet, previewsDir.appending(path: "finder-location-symbol.png"))
print("Rendered icon assets into \(iconDir.path) and previews into \(previewsDir.path)")
