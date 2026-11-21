import SwiftUI

/// A device in the style of the SF Symbol `smartphone`: a solid body around a screen drawn at a
/// third of the ink (half under Increase Contrast). For the kinds SF Symbols has no non-Apple
/// symbol for: the handheld network testers, phone families told apart by their cameras, a
/// foldable and a tablet. Each is a generic silhouette, not a likeness of any product. Drawn on a
/// 24-unit grid, centred and scaled to fit its frame.
struct DeviceGlyph: View {
  enum Kind: CaseIterable {
    /// A tester Ferry has no closer shape for: two ports on top and a key below its screen.
    case tester
    /// A wide handheld with a large screen, three ports on top and a button below.
    case etherScope
    /// A slim body under a wider head that holds two ports.
    case linkRunner
    /// A small screen over four keys, with one port on top.
    case linkRunnerAT
    /// A narrow body under a rounded antenna housing.
    case airCheck
    /// A phone's back, with a camera bar across it.
    case pixel
    /// A phone's back, with three cameras in a column at one corner.
    case galaxy
    /// A foldable phone, open, with a hinge between its two screens.
    case foldable
    case tablet
  }

  let kind: Kind
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ZStack {
      DeviceGlyphOutline(kind: kind, part: .screen)
        .fill(.primary.opacity(contrast == .increased ? 0.5 : 0.3))
      DeviceGlyphOutline(kind: kind, part: .body).fill()
    }
    .accessibilityHidden(true)
  }
}

/// One part of a `DeviceGlyph`: the body with its screen cut out, or the screen. On a phone's
/// back the "screen" is the back panel.
private struct DeviceGlyphOutline: Shape {
  let kind: DeviceGlyph.Kind
  let part: DeviceGlyphPart

  func path(in rect: CGRect) -> Path {
    let grid = GlyphGrid(rect: rect)
    let drawing: (body: Path, screen: Path)
    switch kind {
    case .tester: drawing = grid.tester()
    case .etherScope: drawing = grid.etherScope()
    case .linkRunner: drawing = grid.linkRunner()
    case .linkRunnerAT: drawing = grid.linkRunnerAT()
    case .airCheck: drawing = grid.airCheck()
    case .pixel: drawing = grid.pixel()
    case .galaxy: drawing = grid.galaxy()
    case .foldable: drawing = grid.foldable()
    case .tablet: drawing = grid.tablet()
    }
    return part == .body ? drawing.body : drawing.screen
  }
}

private enum DeviceGlyphPart {
  case body
  case screen
}

/// The 24-unit grid a glyph is drawn on, and each glyph's body and screen. Each body comes with
/// its screen already cut out.
private struct GlyphGrid {
  let unit: CGFloat
  let origin: CGPoint

  init(rect: CGRect) {
    unit = min(rect.width, rect.height) / 24
    origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
  }

  func box(
    _ left: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat
  ) -> Path {
    Path(
      roundedRect: CGRect(
        x: origin.x + left * unit, y: origin.y + top * unit, width: width * unit,
        height: height * unit),
      cornerRadius: radius * unit, style: .continuous)
  }

  func oval(_ left: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Path {
    Path(
      ellipseIn: CGRect(
        x: origin.x + left * unit, y: origin.y + top * unit, width: width * unit,
        height: height * unit))
  }

  func dot(_ centerX: CGFloat, _ centerY: CGFloat, radius: CGFloat) -> Path {
    oval(centerX - radius, centerY - radius, 2 * radius, 2 * radius)
  }

  func tester() -> (body: Path, screen: Path) {
    let screen = box(7, 6.2, 10, 8, 1.2)
    let body = box(5, 4, 14, 19, 3.4)
      .union(box(8.5, 1.6, 2.6, 3, 0.6))
      .union(box(12.9, 1.6, 2.6, 3, 0.6))
      .subtracting(screen)
      .subtracting(dot(12, 18, radius: 1.7))
    return (body, screen)
  }

  func etherScope() -> (body: Path, screen: Path) {
    let screen = box(5.6, 5.2, 12.8, 11.8, 1.2)
    let body = box(3.4, 3, 17.2, 20, 3.6)
      .union(box(6.2, 0.8, 3, 3, 0.6))
      .union(box(10.5, 0.8, 3, 3, 0.6))
      .union(box(14.8, 0.8, 3, 3, 0.6))
      .subtracting(screen)
      .subtracting(box(9.6, 18.7, 4.8, 2.2, 1.1))
    return (body, screen)
  }

  func linkRunner() -> (body: Path, screen: Path) {
    let screen = box(8, 9.6, 8, 10, 1)
    let body = box(6, 6, 12, 17, 3)
      .union(box(4.2, 1.2, 15.6, 6.8, 2))
      .subtracting(screen)
      .subtracting(box(6.8, 3.2, 3.8, 2.8, 0.5))
      .subtracting(box(13.4, 3.2, 3.8, 2.8, 0.5))
    return (body, screen)
  }

  func linkRunnerAT() -> (body: Path, screen: Path) {
    let screen = box(7.6, 5, 8.8, 6.6, 1)
    var body = box(5.4, 3, 13.2, 20, 3.2)
      .union(box(8.8, 1, 6.4, 2.6, 0.6))
      .subtracting(screen)
    for (centerX, centerY) in [(9.6, 14.6), (14.4, 14.6), (9.6, 19.2), (14.4, 19.2)] {
      body = body.subtracting(dot(centerX, centerY, radius: 1.35))
    }
    return (body, screen)
  }

  func airCheck() -> (body: Path, screen: Path) {
    let screen = box(8.4, 8.6, 7.2, 8, 1)
    let body = box(6.6, 6, 10.8, 17, 3)
      .union(oval(4.8, 1, 14.4, 9.4))
      .subtracting(screen)
      .subtracting(dot(12, 19.6, radius: 1.4))
    return (body, screen)
  }

  /// A phone's back: the frame, and the panel inside it.
  private func phoneBack() -> (frame: Path, panel: Path) {
    let panel = box(7.6, 3.1, 8.8, 17.8, 1.8)
    return (box(6, 1.5, 12, 21, 3.2).subtracting(panel), panel)
  }

  func pixel() -> (body: Path, screen: Path) {
    let back = phoneBack()
    return (back.frame.union(box(6, 5, 12, 3.8, 1.9)), back.panel)
  }

  func galaxy() -> (body: Path, screen: Path) {
    let back = phoneBack()
    let lenses = dot(9.9, 5.6, radius: 1.6)
      .union(dot(9.9, 9.6, radius: 1.6))
      .union(dot(9.9, 13.6, radius: 1.6))
    return (back.frame.union(lenses), back.panel)
  }

  func foldable() -> (body: Path, screen: Path) {
    let screen = box(4.2, 5.2, 7.1, 13.6, 1).union(box(12.7, 5.2, 7.1, 13.6, 1))
    return (box(2.5, 3.5, 19, 17, 2.8).subtracting(screen), screen)
  }

  func tablet() -> (body: Path, screen: Path) {
    let screen = box(6, 4, 12, 17, 1.3)
    return (box(3.8, 1.8, 16.4, 21.4, 3.2).subtracting(screen), screen)
  }
}
