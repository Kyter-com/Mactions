import AppKit
import MactionsCore
import SwiftUI

/// Brand marks for each `RunnerOS`, drawn as uniform MONOCHROME, white-tintable
/// glyphs. Sourced from the custom SF Symbol templates under `Media.xcassets`
/// (`logo-apple` / `logo-windows` / `logo-ubuntu`).
///
/// Two render paths, picked automatically:
///   - **Real SF Symbol** (`Image(name, bundle: .module)`) when the asset catalog
///     has been COMPILED by `actool` — i.e. in a real `.app` (Xcode) build.
///   - **Embedded glyph** (the `Regular-S` path data parsed by `SVGSymbol`) when
///     it hasn't — i.e. under `swift build`/`swift run`, which copies the raw
///     `.xcassets` but never runs actool. Visually identical, so the menubar app
///     looks right today and upgrades to true SF Symbols for free once packaged.
///
/// All three are styled through the same `.foregroundStyle(tint)` + `.drawingGroup()`
/// path so they read as a uniform set (white on a dark surface, dark on a light one).
struct OSLogo: View {
  let os: RunnerOS
  var size: CGFloat = 22
  var tint: Color = .primary

  var body: some View {
    Group {
      if Self.bundledSymbolAvailable(symbolName) {
        Image(symbolName, bundle: .module).resizable().scaledToFit()
      } else {
        SVGSymbol(pathData: glyphPath)
      }
    }
    .foregroundStyle(tint)
    .frame(width: size, height: size)
    // Rasterize off the popover's vibrancy material so a Shape fill matches the
    // brightness of a symbol/text mark (see git history for the gray-square bug).
    .drawingGroup()
  }

  private var symbolName: String {
    switch os {
    case .macOS: return "logo-apple"
    case .windows: return "logo-windows"
    case .linux: return "logo-ubuntu"
    }
  }

  private var glyphPath: String {
    switch os {
    case .macOS: return OSLogoSymbol.apple
    case .windows: return OSLogoSymbol.windows
    case .linux: return OSLogoSymbol.ubuntu
    }
  }

  /// Whether the COMPILED custom symbol is present in the module bundle. False
  /// under `swift build` (raw, uncompiled catalog), true in a packaged `.app`.
  /// Cached per name (probe is cheap, but this runs for every logo in a list).
  @MainActor private static var availability: [String: Bool] = [:]
  @MainActor private static func bundledSymbolAvailable(_ name: String) -> Bool {
    if let cached = availability[name] { return cached }
    let exists = Bundle.module.image(forResource: NSImage.Name(name)) != nil
    availability[name] = exists
    return exists
  }
}

/// Renders an SVG path `d` string as a Shape, auto-normalized (aspect-fit,
/// centered) into the target rect. Supports the command set the OS-logo glyphs
/// use (M/L/H/V/C/S/Q/T/Z, absolute + relative); unknown commands (e.g. arcs,
/// which these glyphs don't use) are skipped without crashing.
struct SVGSymbol: Shape {
  let pathData: String

  func path(in rect: CGRect) -> Path {
    let raw = SVGPath.parse(pathData)
    let bounds = raw.boundingRect
    guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
    else { return raw }
    let scale = min(rect.width / bounds.width, rect.height / bounds.height)
    let scaled = raw.applying(CGAffineTransform(scaleX: scale, y: scale))
    let sb = scaled.boundingRect
    return scaled.applying(
      CGAffineTransform(translationX: rect.midX - sb.midX, y: rect.midY - sb.midY))
  }
}

/// Minimal, dependency-free SVG path-data parser → SwiftUI `Path`.
enum SVGPath {
  private enum Token { case cmd(Character); case num(CGFloat) }

  static func parse(_ d: String) -> Path {
    var path = Path()
    let toks = tokenize(d)
    var i = 0
    var cur = CGPoint.zero
    var startPt = CGPoint.zero
    var prevCtrl: CGPoint?
    var cmd: Character = " "

    // Pull the next numeric token, or nil if a command / the end is next. Advances
    // only when it returns a number, so the main loop always makes progress.
    func next() -> CGFloat? {
      guard i < toks.count, case .num(let v) = toks[i] else { return nil }
      i += 1
      return v
    }

    while i < toks.count {
      if case .cmd(let c) = toks[i] { cmd = c; i += 1 }
      switch cmd {
      case "M", "m":
        guard let x = next(), let y = next() else { break }
        cur = cmd == "m" ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        path.move(to: cur)
        startPt = cur
        prevCtrl = nil
        cmd = cmd == "m" ? "l" : "L"  // subsequent coordinate pairs are implicit lineto
      case "L", "l":
        guard let x = next(), let y = next() else { break }
        cur = cmd == "l" ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        path.addLine(to: cur)
        prevCtrl = nil
      case "H", "h":
        guard let x = next() else { break }
        cur = cmd == "h" ? CGPoint(x: cur.x + x, y: cur.y) : CGPoint(x: x, y: cur.y)
        path.addLine(to: cur)
        prevCtrl = nil
      case "V", "v":
        guard let y = next() else { break }
        cur = cmd == "v" ? CGPoint(x: cur.x, y: cur.y + y) : CGPoint(x: cur.x, y: y)
        path.addLine(to: cur)
        prevCtrl = nil
      case "C", "c":
        guard let a = next(), let b = next(), let c2 = next(), let d2 = next(), let e = next(),
          let f = next()
        else { break }
        let rel = cmd == "c"
        let cp1 = rel ? CGPoint(x: cur.x + a, y: cur.y + b) : CGPoint(x: a, y: b)
        let cp2 = rel ? CGPoint(x: cur.x + c2, y: cur.y + d2) : CGPoint(x: c2, y: d2)
        let end = rel ? CGPoint(x: cur.x + e, y: cur.y + f) : CGPoint(x: e, y: f)
        path.addCurve(to: end, control1: cp1, control2: cp2)
        prevCtrl = cp2
        cur = end
      case "S", "s":
        guard let c2x = next(), let c2y = next(), let ex = next(), let ey = next() else { break }
        let rel = cmd == "s"
        let cp2 = rel ? CGPoint(x: cur.x + c2x, y: cur.y + c2y) : CGPoint(x: c2x, y: c2y)
        let end = rel ? CGPoint(x: cur.x + ex, y: cur.y + ey) : CGPoint(x: ex, y: ey)
        let cp1 = prevCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
        path.addCurve(to: end, control1: cp1, control2: cp2)
        prevCtrl = cp2
        cur = end
      case "Q", "q":
        guard let qx = next(), let qy = next(), let ex = next(), let ey = next() else { break }
        let rel = cmd == "q"
        let cp = rel ? CGPoint(x: cur.x + qx, y: cur.y + qy) : CGPoint(x: qx, y: qy)
        let end = rel ? CGPoint(x: cur.x + ex, y: cur.y + ey) : CGPoint(x: ex, y: ey)
        path.addQuadCurve(to: end, control: cp)
        prevCtrl = cp
        cur = end
      case "T", "t":
        guard let ex = next(), let ey = next() else { break }
        let rel = cmd == "t"
        let end = rel ? CGPoint(x: cur.x + ex, y: cur.y + ey) : CGPoint(x: ex, y: ey)
        let cp = prevCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
        path.addQuadCurve(to: end, control: cp)
        prevCtrl = cp
        cur = end
      case "Z", "z":
        path.closeSubpath()
        cur = startPt
        prevCtrl = nil
      default:
        _ = next()  // unknown command — consume a number to guarantee progress
      }
    }
    return path
  }

  private static func tokenize(_ d: String) -> [Token] {
    var tokens: [Token] = []
    let chars = Array(d)
    let n = chars.count
    let commands = Set("MmLlHhVvCcSsQqTtAaZz")
    var i = 0
    while i < n {
      let c = chars[i]
      if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
        i += 1
        continue
      }
      if commands.contains(c) {
        tokens.append(.cmd(c))
        i += 1
        continue
      }
      // Parse a float: optional sign, digits, one dot, optional exponent. A second
      // '.' or a sign (outside an exponent) starts the NEXT number.
      var j = i
      if chars[j] == "+" || chars[j] == "-" { j += 1 }
      var seenDot = false
      while j < n {
        let cj = chars[j]
        if cj.isNumber {
          j += 1
        } else if cj == "." {
          if seenDot { break }
          seenDot = true
          j += 1
        } else if cj == "e" || cj == "E" {
          j += 1
          if j < n, chars[j] == "+" || chars[j] == "-" { j += 1 }
        } else {
          break
        }
      }
      if j > i, let value = Double(String(chars[i..<j])) { tokens.append(.num(CGFloat(value))) }
      i = max(j, i + 1)
    }
    return tokens
  }
}
