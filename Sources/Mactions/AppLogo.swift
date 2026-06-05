import AppKit
import SwiftUI

@MainActor
enum AppLogo {
  /// Runtime fallback for the SwiftPM executable. A packaged Xcode `.app` should
  /// use `Mactions.icon` directly as its App Icon; Xcode/Icon Composer then emits
  /// the platform-correct macOS icon. SwiftPM has no app-icon build setting, so
  /// we approximate the macOS "pre-Tahoe" optical inset: 832 pt visible art on a
  /// 1024 pt canvas, or 96 pt transparent padding per side.
  static let macOSDockInsetRatio: CGFloat = 96.0 / 1024.0

  static func image(size: CGFloat = 256, insetRatio: CGFloat = 0) -> NSImage? {
    guard
      let url = Bundle.module.url(
        forResource: "SVG Image",
        withExtension: "svg",
        subdirectory: "Mactions.icon/Assets"),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }
    let canvasSize = NSSize(width: size, height: size)
    image.size = canvasSize
    guard insetRatio > 0 else { return image }

    let inset = max(0, min(size * insetRatio, size / 2))
    let padded = NSImage(size: canvasSize)
    padded.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    image.draw(
      in: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
      from: NSRect(origin: .zero, size: canvasSize),
      operation: .sourceOver,
      fraction: 1)
    padded.unlockFocus()
    return padded
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
