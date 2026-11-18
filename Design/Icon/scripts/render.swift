// Renders Ferry's icon assets from the SVG layers in Design/Icon/layers.
//
//   swift Design/Icon/scripts/render.swift        (run from the repository root)
//
// Writes:
//   Design/Icon/Ferry.icon/Assets/*.svg        copies of the layers Icon Composer uses
//   Design/Icon/AppIcon.appiconset/*.png       classic icon, squircle and shadow drawn here
//   Design/Icon/MenuBarGlyph-{16,18,32,36}.png template images (black + alpha)
//   Design/Icon/Ferry.png                      512 px icon for the README
//   Design/Icon/preview.png                    review sheet, light and dark
//
// Uses only AppKit: NSImage loads SVG through CoreSVG on macOS 14 and later.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = root.appending(path: "Design/Icon")
let layersDir = iconDir.appending(path: "layers")
guard FileManager.default.fileExists(atPath: layersDir.path) else {
  FileHandle.standardError.write(Data("Run from the repository root.\n".utf8))
  exit(1)
}

func svg(_ name: String) -> NSImage {
  let url = layersDir.appending(path: "\(name).svg")
  guard let image = NSImage(contentsOf: url) else {
    FileHandle.standardError.write(Data("Cannot load \(url.path)\n".utf8))
    exit(1)
  }
  return image
}

let background = svg("background")
let water = svg("water")
let hull = svg("hull")
let cargo = svg("cargo")
let smallHull = svg("hull-small")
let smallCargo = svg("cargo-small")
let hull16 = svg("hull-16")
let cargo16 = svg("cargo-16")
let menuGlyph = NSImage(contentsOf: iconDir.appending(path: "MenuBarGlyph.svg"))!

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
    let glyph =
      px <= 16 ? [background, hull16, cargo16]
      : px <= 32 ? [background, water, smallHull, smallCargo] : [background, water, hull, cargo]
    for layer in glyph {
      layer.draw(in: tile)
    }
    cg.restoreGState()
  }
}

/// Black + alpha only, so macOS can tint it for the menu bar.
func templateGlyph(_ px: Int) -> NSBitmapImageRep {
  bitmap(px, px) { _ in menuGlyph.draw(in: CGRect(x: 0, y: 0, width: px, height: px)) }
}

// Icon Composer bundle: the layers are the source of truth, so copy them in.
let iconAssets = iconDir.appending(path: "Ferry.icon/Assets")
try! FileManager.default.createDirectory(at: iconAssets, withIntermediateDirectories: true)
for name in ["water", "hull", "cargo"] {
  let target = iconAssets.appending(path: "\(name).svg")
  try? FileManager.default.removeItem(at: target)
  try! FileManager.default.copyItem(at: layersDir.appending(path: "\(name).svg"), to: target)
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

for px in [16, 18, 32, 36] {
  write(templateGlyph(px), iconDir.appending(path: "MenuBarGlyph-\(px).png"))
}
write(classicIcon(512), iconDir.appending(path: "Ferry.png"))

// Preview sheet.
func nearestNeighbour(_ rep: NSBitmapImageRep, _ factor: Int) -> NSImage {
  let image = NSImage(size: NSSize(width: rep.pixelsWide * factor, height: rep.pixelsHigh * factor))
  image.addRepresentation(rep)
  return image
}

let sheetWidth = 2600
let panelHeight = 1240
let sheet = bitmap(sheetWidth, panelHeight * 2) { cg in
  let panels: [(String, NSColor, NSColor)] = [
    ("Light", NSColor(white: 0.96, alpha: 1), NSColor(white: 0.1, alpha: 1)),
    ("Dark", NSColor(white: 0.12, alpha: 1), NSColor(white: 0.92, alpha: 1)),
  ]
  for (index, (name, fill, ink)) in panels.enumerated() {
    let originY = CGFloat(panelHeight * (1 - index))
    cg.setFillColor(fill.cgColor)
    cg.fill(CGRect(x: 0, y: originY, width: CGFloat(sheetWidth), height: CGFloat(panelHeight)))
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: ink,
    ]
    func label(_ text: String, _ x: CGFloat, _ y: CGFloat) {
      (text as NSString).draw(at: CGPoint(x: x, y: originY + y), withAttributes: attributes)
    }
    label(name, 40, CGFloat(panelHeight) - 60)

    // Icons at their real pixel sizes, bottoms aligned.
    var x: CGFloat = 40
    let base: CGFloat = 120
    for px in [1024, 512, 128, 32, 16] {
      // NSImageRep.draw(in:) copies pixels; composite instead so the transparent corners show.
      classicIcon(px).draw(
        in: CGRect(x: x, y: originY + base, width: CGFloat(px), height: CGFloat(px)), from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
      label("\(px)", x, base - 50)
      x += CGFloat(px) + 40
    }

    // 8x nearest-neighbour zooms of the small renders, to judge the pixels.
    var zoomX: CGFloat = 1960
    for px in [16, 32] {
      let zoomed = nearestNeighbour(classicIcon(px), 8)
      NSGraphicsContext.current?.imageInterpolation = .none
      zoomed.draw(in: CGRect(x: zoomX, y: originY + base, width: CGFloat(px * 8), height: CGFloat(px * 8)))
      NSGraphicsContext.current?.imageInterpolation = .high
      label("\(px) px x8", zoomX, base - 50)
      zoomX += CGFloat(px * 8) + 40
    }

    // Menu bar glyph: tinted the way macOS tints template images, at 1x and at 8x.
    let bar = CGRect(x: 1960, y: originY + 560, width: 520, height: 44)
    cg.setFillColor((index == 0 ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.2, alpha: 1)).cgColor)
    cg.fill(bar)
    let tint = index == 0 ? NSColor.black : NSColor.white
    func tinted(_ rep: NSBitmapImageRep) -> NSImage {
      let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
      image.lockFocus()
      rep.draw(in: NSRect(origin: .zero, size: image.size))
      tint.set()
      NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
      image.unlockFocus()
      return image
    }
    tinted(templateGlyph(18)).draw(in: CGRect(x: bar.minX + 20, y: bar.minY + 13, width: 18, height: 18))
    let symbol = NSImage(
      systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)!
      .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
    let symbolTinted = NSImage(size: symbol.size, flipped: false) { rect in
      symbol.draw(in: rect)
      tint.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    symbolTinted.draw(at: CGPoint(x: bar.minX + 70, y: bar.minY + (44 - symbol.size.height) / 2),
      from: .zero, operation: .sourceOver, fraction: 1)
    label("menu bar: glyph | SF Symbol", 1960, 520)
    NSGraphicsContext.current?.imageInterpolation = .none
    tinted(templateGlyph(18)).draw(in: CGRect(x: 1960, y: originY + 680, width: 144, height: 144))
    tinted(templateGlyph(36)).draw(in: CGRect(x: 2140, y: originY + 680, width: 144, height: 144))
    NSGraphicsContext.current?.imageInterpolation = .high
    label("glyph 18 px x8 | 36 px x4", 1960, 840)
  }
}
write(sheet, iconDir.appending(path: "preview.png"))
print("Rendered icon assets into \(iconDir.path)")
