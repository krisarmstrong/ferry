import SwiftUI

/// A device in the style of the SF Symbol `smartphone`: a solid body around a screen drawn at a
/// third of the ink. For the kinds SF Symbols has no non-Apple symbol for: a handheld network
/// tester, with two ports on top and a key below its screen, and a tablet. Drawn on a 24-unit
/// grid, centred and scaled to fit its frame.
struct DeviceGlyph: View {
  enum Kind {
    case tester
    case tablet
  }

  let kind: Kind

  var body: some View {
    ZStack {
      DeviceGlyphOutline(kind: kind, part: .screen).fill(.primary.opacity(0.3))
      DeviceGlyphOutline(kind: kind, part: .body).fill()
    }
    .accessibilityHidden(true)
  }
}

/// One part of a `DeviceGlyph`: the body with its screen cut out, or the screen.
private struct DeviceGlyphOutline: Shape {
  let kind: DeviceGlyph.Kind
  let part: DeviceGlyphPart

  func path(in rect: CGRect) -> Path {
    let unit = min(rect.width, rect.height) / 24
    let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
    func box(
      _ left: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat
    )
      -> Path
    {
      Path(
        roundedRect: CGRect(
          x: origin.x + left * unit, y: origin.y + top * unit, width: width * unit,
          height: height * unit),
        cornerRadius: radius * unit, style: .continuous)
    }
    switch kind {
    case .tester:
      let screen = box(7, 6.2, 10, 8, 1.2)
      guard part == .body else { return screen }
      let key = Path(
        ellipseIn: CGRect(
          x: origin.x + 10.3 * unit, y: origin.y + 16.3 * unit, width: 3.4 * unit,
          height: 3.4 * unit))
      return box(5, 4, 14, 19, 3.4)
        .union(box(8.5, 1.6, 2.6, 3, 0.6))
        .union(box(12.9, 1.6, 2.6, 3, 0.6))
        .subtracting(screen)
        .subtracting(key)
    case .tablet:
      let screen = box(6, 4, 12, 17, 1.3)
      guard part == .body else { return screen }
      return box(3.8, 1.8, 16.4, 21.4, 3.2).subtracting(screen)
    }
  }
}

private enum DeviceGlyphPart {
  case body
  case screen
}
