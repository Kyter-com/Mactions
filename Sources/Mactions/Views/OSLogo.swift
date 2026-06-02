import MactionsCore
import SwiftUI

/// Brand marks for each `RunnerOS`, drawn as scalable vectors (no bundled image
/// assets, so they stay crisp at any size and adapt to light/dark + tinting):
///   - macOS  → `apple.logo` SF Symbol (Apple's own mark; follows `.primary`).
///   - Windows → the 4-pane logo, in Windows blue.
///   - Linux  → a simplified flat Tux.
///
/// To swap in a real bundled image later, replace a branch with
/// `Image("logo-name")` after adding an asset catalog to the target — the call
/// sites (`OSLogo(os:size:)`) don't change.
struct OSLogo: View {
  let os: RunnerOS
  var size: CGFloat = 22

  var body: some View {
    switch os {
    case .macOS:
      Image(systemName: "apple.logo")
        .font(.system(size: size * 0.95))
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
    case .windows:
      WindowsLogo().frame(width: size, height: size)
    case .linux:
      TuxLogo().frame(width: size, height: size)
    }
  }
}

/// The modern Windows mark: a 2×2 grid of squares in Windows blue.
private struct WindowsLogo: View {
  private let blue = Color(red: 0 / 255, green: 120 / 255, blue: 212 / 255)
  var body: some View {
    GeometryReader { geo in
      let s = min(geo.size.width, geo.size.height)
      let gap = s * 0.11
      let cell = (s - gap) / 2
      ZStack(alignment: .topLeading) {
        ForEach(0..<2, id: \.self) { row in
          ForEach(0..<2, id: \.self) { col in
            RoundedRectangle(cornerRadius: s * 0.05)
              .fill(blue)
              .frame(width: cell, height: cell)
              .offset(x: CGFloat(col) * (cell + gap), y: CGFloat(row) * (cell + gap))
          }
        }
      }
      .frame(width: s, height: s, alignment: .topLeading)
    }
  }
}

/// A simplified flat Tux (the Linux mascot): black body, white belly + face,
/// orange beak + feet. Coordinates are normalized to the frame so it scales. (On
/// the Linux tile it's shown dimmed/"soon", so the black body on a dark popover is
/// acceptable; swap in a bundled asset if you want a polished mark.)
private struct TuxLogo: View {
  var body: some View {
    Canvas { ctx, size in
      let s = min(size.width, size.height)
      func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
      }
      func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

      // Feet (orange) — drawn first so the body overlaps their tops.
      ctx.fill(Path(ellipseIn: rect(0.28, 0.82, 0.20, 0.12)), with: .color(.orange))
      ctx.fill(Path(ellipseIn: rect(0.52, 0.82, 0.20, 0.12)), with: .color(.orange))
      // Body (black).
      ctx.fill(Path(ellipseIn: rect(0.18, 0.14, 0.64, 0.76)), with: .color(.black))
      // Belly (white).
      ctx.fill(Path(ellipseIn: rect(0.30, 0.40, 0.40, 0.48)), with: .color(.white))
      // Face patch (white) behind the eyes.
      ctx.fill(Path(ellipseIn: rect(0.35, 0.20, 0.30, 0.24)), with: .color(.white))
      // Eyes (black).
      ctx.fill(Path(ellipseIn: rect(0.43, 0.25, 0.05, 0.08)), with: .color(.black))
      ctx.fill(Path(ellipseIn: rect(0.52, 0.25, 0.05, 0.08)), with: .color(.black))
      // Beak (orange triangle).
      var beak = Path()
      beak.move(to: pt(0.44, 0.37))
      beak.addLine(to: pt(0.56, 0.37))
      beak.addLine(to: pt(0.50, 0.45))
      beak.closeSubpath()
      ctx.fill(beak, with: .color(.orange))
    }
  }
}
