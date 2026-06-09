import AppKit
import MactionsCore
import SwiftUI

/// App entry point. The PRIMARY UI is an AppKit-owned window (`DashboardView`,
/// managed by `DashboardWindowController`) that the delegate opens on launch —
/// deliberately a `Settings` scene below, NOT a `WindowGroup`, which would
/// auto-open a second window competing with the AppKit one.
///
/// Settings now live IN the app: `SettingsRootView` is shown in a non-modal
/// companion window (`SettingsWindowController`), NOT the macOS ⌘, preferences
/// window. The old `showSettingsWindow:` action never reached a responder from
/// the AppKit-hosted window, so the toolbar gear was dead. The
/// `Settings { EmptyView() }` scene below is kept ONLY as the "don't auto-open a
/// window" trick; the standard Settings menu item is replaced so ⌘, opens the
/// in-app Settings window instead of the empty scene.
///
/// Quitting the app is the "go offline" signal — the delegate deregisters runners
/// before letting termination complete.
@main
struct MactionsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    // An empty `Settings` scene purely suppresses the auto-opened WindowGroup
    // window; it's never shown (the replaced menu item below opens the in-app
    // Settings window instead). The real primary window is AppKit-owned (see
    // DashboardWindowController, shown from applicationDidFinishLaunching).
    Settings { EmptyView() }
      .commands {
        // Route the standard "Settings… (⌘,)" menu item to the in-app Settings
        // window rather than the (empty, AppKit-unreachable) preferences scene.
        CommandGroup(replacing: .appSettings) {
          Button("Settings…") { AppState.shared.presentSettings() }
            .keyboardShortcut(",", modifiers: .command)
        }
      }
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
    if let icon = AppLogo.image(insetRatio: AppLogo.macOSDockInsetRatio) {
      NSApp.applicationIconImage = icon
    }
    DashboardWindowController.shared.show()

    // System sleep suspends our VMs/containers; their runner agents then drop to
    // offline-but-busy on GitHub, orphaning any in-flight job (left "stuck" at its
    // last step). Take the fleet offline before sleep — like Quit, this is a clean
    // "go offline" that deregisters the runners — and bring it back on wake if it
    // was online. (If sleep beats the async teardown, the reconcile loop's
    // sustained-offline prune reaps the ghosts within the grace window after wake;
    // this just makes the common laptop-lid-close case clean.)
    //
    // IDLE sleep never reaches this handler: AppState holds a
    // PreventUserIdleSystemSleep assertion while the fleet is online. Found live
    // (2026-06-09, release v0.0.21): the display idled off mid-release, macOS
    // initiated a sleep attempt, willSleep fired and killed two BUSY build legs
    // ("The operation was canceled" / "runner lost communication"), then didWake
    // re-provisioned 20s later. With the assertion, this path now means
    // lid-close / user-initiated sleep — the machine really is going away, and
    // a clean deregister-first teardown beats GitHub-side ghosts.
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(
      self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification,
      object: nil)
    nc.addObserver(
      self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
  }

  /// True iff the fleet was online when the Mac went to sleep, so `systemDidWake`
  /// knows to bring it back. Main-actor state.
  private var wasOnlineBeforeSleep = false

  @objc private func systemWillSleep(_ notification: Notification) {
    let state = AppState.shared
    guard state.state != .offline else {
      wasOnlineBeforeSleep = false
      return
    }
    wasOnlineBeforeSleep = true
    // Best-effort within the brief pre-sleep window. stop() deregisters FIRST, so
    // even if the local VM teardown doesn't finish before sleep, the registration
    // removal (the part that prevents a GitHub-side ghost) lands fast.
    Task { @MainActor in await state.goOfflineAndWait() }
  }

  @objc private func systemDidWake(_ notification: Notification) {
    guard wasOnlineBeforeSleep else { return }
    wasOnlineBeforeSleep = false
    // Resume the fleet we paused for sleep.
    AppState.shared.goOnline()
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
