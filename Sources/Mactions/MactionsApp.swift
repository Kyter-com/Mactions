import AppKit
import MactionsCore
import SwiftUI

/// Menubar entry point. The whole UI hangs off a single `MenuBarExtra`; there's
/// no main window. Quitting the app is the "go offline" signal — the delegate
/// deregisters runners before letting termination complete.
@main
struct MactionsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @ObservedObject private var app = AppState.shared

  var body: some Scene {
    MenuBarExtra("Mactions", systemImage: app.menuBarSymbol) {
      MenuContentView()
        .environmentObject(app)
        .frame(width: 340)
    }
    .menuBarExtraStyle(.window)
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
    // Accessory = menubar-only, no dock icon, no app-switcher entry. The optional
    // dashboard window flips this to .regular while it's open (see
    // DashboardWindowController) and back to .accessory on close.
    NSApp.setActivationPolicy(.accessory)
  }

  /// Closing the dashboard window must NOT quit the app — Mactions lives in the
  /// menu bar and quitting is what takes runners offline. Only the menu's Quit /
  /// ⌘Q (NSApp.terminate) ends the app, via applicationShouldTerminate below.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
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
