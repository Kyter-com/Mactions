import Foundation

/// The bundle that carries the app's resources (`Media.xcassets`, `Mactions.icon`).
///
/// SwiftPM synthesizes `Bundle.module` for a target with resources; an Xcode app
/// target has no `Bundle.module` (its resources live in the main bundle). Routing
/// resource lookups through here keeps BOTH builds working: `swift run` (the dev
/// path) and the Xcode app target (which compiles `Mactions.icon` into the real
/// Liquid Glass AppIcon).
enum AppResources {
  static var bundle: Bundle {
    #if SWIFT_PACKAGE
    return .module
    #else
    return .main
    #endif
  }
}
