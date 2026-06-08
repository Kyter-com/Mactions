import AppKit
import SwiftUI

@MainActor
enum AppLogo {
  /// Runtime fallback for the SwiftPM executable. A packaged Xcode `.app` should
  /// use `Mactions.icon` directly as its App Icon; Xcode/Icon Composer then emits
  /// the platform-correct macOS (Liquid Glass) icon. SwiftPM has no app-icon
  /// build setting, so we approximate it: composite the glyph layer onto the
  /// icon's dark rounded-rect background, with the macOS optical inset (96 pt
  /// transparent padding on a 1024 pt canvas) for the dock.
  static let macOSDockInsetRatio: CGFloat = 96.0 / 1024.0

  /// macOS continuous-corner ("squircle") radius as a fraction of the tile edge.
  private static let cornerRatio: CGFloat = 0.2237

  /// The icon tile's background gradient, mirrored from `Mactions.icon/icon.json`
  /// (dark P3 gray, top → bottom). `icon.json` stays the source of truth for the
  /// real composed AppIcon; this only approximates it for the `swift run` dev
  /// build's dock icon (Icon Composer's glyph layer is transparent on its own).
  private static let bgTop = NSColor(displayP3Red: 0.14355, green: 0.15576, blue: 0.18811, alpha: 1)
  private static let bgBottom = NSColor(displayP3Red: 0.22803, green: 0.23901, blue: 0.26831, alpha: 1)

  /// The transparent glyph layer (`Mactions.icon/Assets/Group.svg`) at `size`.
  private static func glyph(size: CGFloat) -> NSImage? {
    guard
      let url = AppResources.bundle.url(
        forResource: "Group", withExtension: "svg", subdirectory: "Mactions.icon/Assets"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.size = NSSize(width: size, height: size)
    return image
  }

  static func image(size: CGFloat = 256, insetRatio: CGFloat = 0) -> NSImage? {
    guard let glyph = glyph(size: size) else { return nil }
    let canvasSize = NSSize(width: size, height: size)
    let inset = max(0, min(size * insetRatio, size / 2))
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    let out = NSImage(size: canvasSize)
    out.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    // Dark rounded-rect background (the icon "tile") under the glyph.
    let radius = tile.width * cornerRatio
    let bg = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    if let gradient = NSGradient(colors: [bgTop, bgBottom]) {
      gradient.draw(in: bg, angle: -90)  // top → bottom
    } else {
      bgBottom.setFill()
      bg.fill()
    }
    // Glyph on top — its SVG carries its own internal margin, so it sits inside
    // the tile without touching the edges.
    glyph.draw(
      in: tile, from: NSRect(origin: .zero, size: glyph.size), operation: .sourceOver, fraction: 1)
    out.unlockFocus()
    return out
  }
}

struct AppLogoView: View {
  var size: CGFloat = 30

  var body: some View {
    Group {
      if let image = AppLogo.image(size: size * 2) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else if let appIcon = NSImage(named: NSImage.applicationIconName) {
        // Xcode app target: the glyph SVG isn't a loose resource (it's compiled
        // into the AppIcon), so fall back to the app's own composed icon.
        Image(nsImage: appIcon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Image(systemName: "chevron.right.square.fill")
          .resizable()
          .scaledToFit()
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.primary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
