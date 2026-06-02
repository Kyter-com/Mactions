import AppKit
import SwiftUI

/// Owns the optional full dashboard window — an AppKit `NSWindow` hosting the
/// SwiftUI `DashboardView`. The app is normally a menubar-only accessory (no dock
/// icon); the dashboard is opt-in.
///
/// Dock behavior (chosen): **dockless unless the window is open.** Showing the
/// window flips the app to `.regular` (dock icon + app-switcher entry); closing
/// it flips back to `.accessory`. Closing the window is NOT quitting — only
/// `NSApp.terminate` (the menu's Quit / ⌘Q) routes through
/// `AppDelegate.applicationShouldTerminate`, which takes the fleet offline. So
/// the dashboard can be opened and closed freely without disturbing runners.
///
/// The window is created once and reused (`isReleasedWhenClosed = false`); the
/// SwiftUI content binds to `AppState.shared`, the same instance the menubar
/// popover uses, so both surfaces stay in sync for free.
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
      win.title = "Mactions"
      win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      win.setContentSize(NSSize(width: 760, height: 560))
      win.contentMinSize = NSSize(width: 620, height: 420)
      win.center()
      win.isReleasedWhenClosed = false  // reuse the instance across open/close
      win.identifier = NSUserInterfaceItemIdentifier("mactions-dashboard")
      win.delegate = self
      window = win
    }
    // Dock icon + app-switcher entry while the dashboard is open.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { return }
    // Bring the window fully forward and make it key + main so focus lands HERE,
    // not on the menubar popover that launched it. orderFrontRegardless is kept on
    // purpose: the app starts as an .accessory (menubar-only), and a just-promoted
    // accessory app can fail to front a window with makeKeyAndOrderFront alone.
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    window.makeMain()
    // Don't leave the segmented tab control focus-ringed: park first responder on
    // the content view so the window reads as focused without a control selected.
    window.makeFirstResponder(window.contentView)
    // Sample live memory only while the dashboard is visible.
    AppState.shared.startMemorySampling()
  }

  // MARK: NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    // Back to menubar-only — no lingering dock icon once the dashboard is gone.
    // The window object is retained (isReleasedWhenClosed = false) and reused on
    // the next show(). This is purely a UI-presence change; it never touches the
    // fleet (closing ≠ quitting).
    NSApp.setActivationPolicy(.accessory)
    AppState.shared.stopMemorySampling()
  }
}
