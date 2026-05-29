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

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Accessory = menubar-only, no dock icon, no app-switcher entry.
    NSApp.setActivationPolicy(.accessory)
  }

  /// Bring runners offline before we actually quit. Reply `terminateLater` and
  /// finish the async teardown, with a hard timeout so a hung network call
  /// can't wedge quit. Ephemeral runners + GitHub's offline sweep are the
  /// backstop if this is skipped (force-quit, crash).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let state = AppState.shared
    if state.state == .offline { return .terminateNow }

    var replied = false
    let reply = {
      if !replied {
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
      }
    }
    Task { @MainActor in
      await state.goOfflineAndWait()
      reply()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: reply)
    return .terminateLater
  }
}
