import AppKit
import MactionsCore
import SwiftUI

/// The app's single source of truth. Wraps the UI-free `RunnerOrchestrator`,
/// owns config + auth, and republishes change notifications to SwiftUI. A
/// singleton so the `AppDelegate` can reach it during termination.
@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  // Fleet config (persisted to UserDefaults).
  @Published var owner = ""
  @Published var repo = ""
  @Published var labelsText = "self-hosted,macOS,mactions"
  @Published var desiredCount = 1
  /// OAuth App client id for the device-flow sign-in. Optional: the PAT path
  /// works without it.
  @Published var clientId = ""

  // Auth.
  @Published var isSignedIn = false
  @Published var authBusy = false
  /// Non-nil while we're waiting for the user to approve the device code.
  @Published var pendingDeviceCode: GitHubAuth.DeviceCode?

  // Fleet runtime.
  @Published var state: FleetState = .offline
  @Published var runners: [ManagedRunner] = []
  @Published var statusMessage: String?

  private var orchestrator: RunnerOrchestrator?
  private let defaults = UserDefaults.standard

  init() {
    owner = defaults.string(forKey: "owner") ?? ""
    repo = defaults.string(forKey: "repo") ?? ""
    labelsText = defaults.string(forKey: "labels") ?? labelsText
    desiredCount = max(1, defaults.integer(forKey: "desiredCount"))
    clientId = defaults.string(forKey: "clientId") ?? ""
    isSignedIn = TokenStore.load() != nil
  }

  var menuBarSymbol: String {
    switch state {
    case .offline: return "bolt.slash"
    case .starting, .stopping: return "bolt.badge.clock"
    case .online: return "bolt.fill"
    }
  }

  func saveConfig() {
    defaults.set(owner, forKey: "owner")
    defaults.set(repo, forKey: "repo")
    defaults.set(labelsText, forKey: "labels")
    defaults.set(desiredCount, forKey: "desiredCount")
    defaults.set(clientId, forKey: "clientId")
  }

  var labels: [String] {
    labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  // MARK: Auth

  /// True if the GitHub CLI is installed — enables the one-click reuse path.
  var gitHubCLIAvailable: Bool { GitHubCLIAuth.isAvailable() }

  /// Easiest path: borrow the token the user's `gh` CLI already holds.
  func signInWithGitHubCLI() {
    do {
      let token = try GitHubCLIAuth.currentToken()
      try TokenStore.save(token)
      isSignedIn = true
      statusMessage = "Signed in via GitHub CLI."
    } catch {
      statusMessage = "\(error)"
    }
  }

  func signInWithDeviceFlow() {
    guard !clientId.isEmpty else {
      statusMessage = "Add an OAuth client id in Settings, or paste a token below."
      return
    }
    authBusy = true
    statusMessage = nil
    Task {
      do {
        let code = try await GitHubAuth.requestDeviceCode(clientId: clientId)
        pendingDeviceCode = code
        NSWorkspace.shared.open(code.verificationURI)
        let token = try await GitHubAuth.pollForToken(clientId: clientId, deviceCode: code)
        try TokenStore.save(token)
        isSignedIn = true
        statusMessage = "Signed in."
      } catch {
        statusMessage = "Sign-in failed: \(error)"
      }
      pendingDeviceCode = nil
      authBusy = false
    }
  }

  func signInWithToken(_ token: String) {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try TokenStore.save(trimmed)
      isSignedIn = true
      statusMessage = "Token saved."
    } catch {
      statusMessage = "Couldn't store the token: \(error)"
    }
  }

  func signOut() {
    Task { await goOfflineAndWait() }
    try? TokenStore.clear()
    isSignedIn = false
    statusMessage = "Signed out."
  }

  // MARK: Fleet

  func toggleOnline() {
    state == .offline ? goOnline() : goOffline()
  }

  func goOnline() {
    guard let token = TokenStore.load() else { statusMessage = "Sign in first."; return }
    guard !owner.isEmpty, !repo.isEmpty else { statusMessage = "Set owner and repo first."; return }
    saveConfig()
    // Sweep anything a previous crash/force-quit orphaned before we start.
    HostCleanup.sweepOrphans()
    statusMessage = "Preparing runner agent…"
    Task {
      do {
        let template = try await RunnerInstaller.ensureInstalled(token: token)
        let client = GitHubClient(owner: owner, repo: repo, token: token)
        let factory = LocalProcessProviderFactory(
          templateDirectory: template, runsRoot: HostCleanup.runsRoot())
        let fleet = FleetConfig(owner: owner, repo: repo, labels: labels, desiredCount: desiredCount)
        let orch = RunnerOrchestrator(controlPlane: client, factory: factory, config: fleet)
        orch.onChange = { [weak self] in self?.sync() }
        orchestrator = orch
        await orch.start()
        statusMessage = "Online for \(owner)/\(repo)."
      } catch {
        statusMessage = "Failed to start: \(error)"
      }
    }
  }

  func goOffline() {
    Task { await goOfflineAndWait() }
  }

  func goOfflineAndWait() async {
    await orchestrator?.stop()
    // Sweep any per-run working copies left behind (there shouldn't be any —
    // each run wipes its own — but belt and suspenders).
    HostCleanup.purgeRuns()
    sync()
    statusMessage = "Offline."
  }

  /// Remove everything Mactions wrote to disk: the cached runner agent and all
  /// per-run files. Offline-only so we never yank a running job's files.
  func cleanUpHostFiles() {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    HostCleanup.purgeAll()
    statusMessage = "Removed the cached agent and all run files."
  }

  private func sync() {
    guard let orchestrator else { return }
    state = orchestrator.state
    runners = orchestrator.runners
    if let err = orchestrator.lastError { statusMessage = err }
  }
}
