import AppKit
import SwiftUI

/// Owns the app's primary window — an AppKit `NSWindow` hosting the SwiftUI
/// `DashboardView`. Mactions is a regular windowed app (`.regular` activation
/// policy, set once at launch), so the dock icon + app-switcher entry persist
/// whether or not the window is visible.
///
/// Closing the window is NOT quitting — only `NSApp.terminate` (Quit / ⌘Q)
/// routes through `AppDelegate.applicationShouldTerminate`, which takes the
/// fleet offline. After a close the app keeps running with no visible window;
/// clicking the dock icon reopens it (`applicationShouldHandleReopen`). So the
/// window can be opened and closed freely without disturbing runners.
///
/// The window is created once and reused (`isReleasedWhenClosed = false`); the
/// SwiftUI content binds to `AppState.shared`, so it's always a live mirror of
/// the fleet.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
  static let shared = DashboardWindowController()

  private var window: NSWindow?

  /// Show (creating on first use) and focus the dashboard window.
  func show() {
    if window == nil {
      let hosting = NSHostingController(
        rootView: DashboardView().environmentObject(AppState.shared))
      let win = NSWindow(contentViewController: hosting)
      win.title = "Mactions"  // kept for Mission Control / Window menu
      // The in-content header already shows "Mactions" + status, so hide the
      // titlebar title and let it go transparent for a cleaner, modern chrome
      // (Rune-style) — without .fullSizeContentView, so content stays clear of
      // the traffic-light buttons.
      win.titleVisibility = .hidden
      win.titlebarAppearsTransparent = true
      win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      win.setContentSize(NSSize(width: 1000, height: 680))
      win.contentMinSize = NSSize(width: 820, height: 560)
      win.center()
      win.isReleasedWhenClosed = false  // reuse the instance across open/close
      win.identifier = NSUserInterfaceItemIdentifier("mactions-dashboard")
      win.delegate = self
      window = win
    }
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { return }
    // Bring the window fully forward and make it key + main so focus lands here.
    // orderFrontRegardless is kept on purpose so a reopen (e.g. via the dock icon)
    // reliably fronts the window even when the app isn't currently active.
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    window.makeMain()
    // Park first responder on the content view so the window reads as focused
    // without a sidebar/control caught in the focus ring.
    window.makeFirstResponder(window.contentView)
    // Sample live memory only while the dashboard is visible.
    AppState.shared.startMemorySampling()
  }

  // MARK: NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    // The app stays `.regular` (dock icon persists) so the dock-icon reopen path
    // keeps working after a close. The window object is retained
    // (isReleasedWhenClosed = false) and reused on the next show(). This is purely
    // a UI-presence change; it never touches the fleet (closing ≠ quitting).
    AppState.shared.stopMemorySampling()
  }
}
