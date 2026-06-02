import AppKit
import MactionsCore
import SwiftUI

/// App entry point. The real UI is an AppKit-owned window (`DashboardView`,
/// managed by `DashboardWindowController`) that the delegate opens on launch —
/// not a SwiftUI `WindowGroup`, which would create a second, duplicate window
/// competing with the AppKit one. SwiftPM `@main App` still needs *a* Scene, so
/// this declares an empty `Settings` scene as a placeholder. Quitting the app is
/// the "go offline" signal — the delegate deregisters runners before letting
/// termination complete.
@main
struct MactionsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    // Placeholder scene only; the primary window is AppKit-owned (see
    // DashboardWindowController, shown from AppDelegate.applicationDidFinishLaunching).
    Settings { EmptyView() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Guards `NSApp.reply(toApplicationShouldTerminate:)` so it fires exactly once
  /// — whichever of teardown / the safety cap reaches it first. Main-actor state,
  /// so no lock + no Sendable gymnastics.
  private var terminationReplied = false
  private func replyToTerminate() {
    guard !terminationReplied else { return }
    terminationReplied = true
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Regular windowed app: dock icon + app-switcher entry, and the dashboard
    // window opens on launch. Closing the window keeps the app (+ fleet) running;
    // clicking the dock icon reopens it (applicationShouldHandleReopen below).
    NSApp.setActivationPolicy(.regular)
    DashboardWindowController.shared.show()
  }

  /// Closing the dashboard window must NOT quit the app — quitting is what takes
  /// runners offline. Only the app's Quit / ⌘Q (NSApp.terminate) ends the app,
  /// via applicationShouldTerminate below.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Clicking the dock icon while the (only) window is closed reopens it — the
  /// app stays running with no visible window after the user closes the dashboard.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    DashboardWindowController.shared.show()
    return true
  }

  /// Bring runners offline before we actually quit. Reply `terminateLater` and
  /// finish the async teardown, with a hard timeout so a hung network call
  /// can't wedge quit. Ephemeral runners + GitHub's offline sweep are the
  /// backstop if this is skipped (force-quit, crash).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let state = AppState.shared
    if state.state == .offline { return .terminateNow }

    // Two independent main-actor tasks race to reply: the teardown, and a 6 s
    // safety cap so a hung network call can't wedge quit. `replyToTerminate()`
    // is idempotent, so whichever finishes first wins and the other is a no-op.
    Task { @MainActor in
      await state.goOfflineAndWait()
      replyToTerminate()
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
      replyToTerminate()
    }
    return .terminateLater
  }
}
