import AppKit
import SwiftUI

/// Owns the Settings window — a real, NON-MODAL `NSWindow` hosting `SettingsRootView`,
/// so it can sit BESIDE the dashboard instead of a modal sheet that overlays the
/// live runner list and traps a running base build. The user wanted settings in
/// the app (not the macOS ⌘, preferences window), and a companion window is the
/// in-app form that doesn't block the main window.
///
/// Created once and reused (`isReleasedWhenClosed = false`); the content binds to
/// `AppState.shared`, so it always mirrors current state. Closing it is harmless
/// (the app stays `.regular`, `applicationShouldTerminateAfterLastWindowClosed`
/// is false), exactly like the dashboard window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  private var window: NSWindow?

  /// Show (creating on first use) and focus the Settings window.
  func show() {
    if window == nil {
      let hosting = NSHostingController(
        rootView: SettingsRootView().environmentObject(AppState.shared))
      let win = NSWindow(contentViewController: hosting)
      win.title = "Settings"
      win.styleMask = [.titled, .closable, .miniaturizable]
      win.setContentSize(NSSize(width: 540, height: 600))
      win.isReleasedWhenClosed = false  // reuse across open/close
      win.identifier = NSUserInterfaceItemIdentifier("mactions-settings")
      win.delegate = self
      win.center()
      window = win
    }
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { return }
    window.makeKeyAndOrderFront(nil)
  }
}
