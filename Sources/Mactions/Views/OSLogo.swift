import MactionsCore
import SwiftUI

/// Brand marks for each `RunnerOS`, drawn as scalable MONOCHROME vectors that read
/// as a uniform set. CRITICAL for uniformity: all three are styled through the
/// SAME `.foregroundStyle(tint)` path (the Apple SF Symbol + the Windows/Tux
/// `Shape`s). A `Shape.fill(Color)` instead renders grayer than symbol/text
/// content inside the popover's vibrancy material — which is why the Windows
/// squares previously looked gray next to the white Apple logo. `.primary` adapts
/// (white on a dark popover, dark on a light one), so they're never invisible.
///   - macOS  → `apple.logo` SF Symbol.
///   - Windows → the 4-pane logo (a 2×2 grid).
///   - Linux  → a simple Tux silhouette.
///
/// To swap in a real bundled image later, replace a branch with
/// `Image("logo-name").renderingMode(.template)` — the call sites don't change.
struct OSLogo: View {
  let os: RunnerOS
  var size: CGFloat = 22
  var tint: Color = .primary

  var body: some View {
    Group {
      switch os {
      case .macOS:
        // The Apple glyph reads optically smaller than a filled square, so size it
        // to the full box; the 4-pane / penguin get a slight inset to match.
        Image(systemName: "apple.logo")
          .font(.system(size: size, weight: .regular))
      case .windows:
        WindowsPanes().frame(width: size * 0.86, height: size * 0.86)
      case .linux:
        TuxShape().frame(width: size * 0.92, height: size * 0.92)
      }
    }
    .foregroundStyle(tint)
    .frame(width: size, height: size)
    // Rasterize off the popover's vibrancy material (NSVisualEffectView): without
    // this, a Shape FILL gets blended with the background (a muted/greenish cast)
    // while an SF Symbol renders as bright "vibrant content" — so the Windows
    // squares looked grayer than the white Apple glyph despite the same tint.
    // drawingGroup composites all three to opaque pixels at the resolved color, so
    // they come out identical.
    .drawingGroup()
  }
}

/// The Windows mark: a 2×2 grid of rounded squares (filled by the inherited
/// foreground style, NOT `.fill(Color)`, so it matches the symbol's white).
private struct WindowsPanes: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height)
    let ox = (rect.width - s) / 2
    let oy = (rect.height - s) / 2
    let gap = s * 0.12
    let cell = (s - gap) / 2
    let r = s * 0.06
    var p = Path()
    for row in 0..<2 {
      for col in 0..<2 {
        let x = ox + CGFloat(col) * (cell + gap)
        let y = oy + CGFloat(row) * (cell + gap)
        p.addRoundedRect(
          in: CGRect(x: x, y: y, width: cell, height: cell),
          cornerSize: CGSize(width: r, height: r))
      }
    }
    return p
  }
}

/// A simple flat Tux silhouette (body + head, little flippers + feet, a beak) as a
/// single `Shape`, filled by the inherited foreground style so it's the SAME white
/// as the other marks. A solid silhouette (no punched eyes) keeps it on the single
/// `.foregroundStyle` path; it still reads as a penguin at tile size.
private struct TuxShape: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height)
    let ox = (rect.width - s) / 2
    let oy = (rect.height - s) / 2
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
      CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
    }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
    var p = Path()
    p.addEllipse(in: box(0.30, 0.82, 0.16, 0.12))  // left foot
    p.addEllipse(in: box(0.54, 0.82, 0.16, 0.12))  // right foot
    p.addEllipse(in: box(0.14, 0.40, 0.16, 0.34))  // left flipper
    p.addEllipse(in: box(0.70, 0.40, 0.16, 0.34))  // right flipper
    p.addEllipse(in: box(0.26, 0.10, 0.48, 0.80))  // body + head
    p.move(to: pt(0.45, 0.30))  // beak
    p.addLine(to: pt(0.55, 0.30))
    p.addLine(to: pt(0.50, 0.37))
    p.closeSubpath()
    return p
  }
}
