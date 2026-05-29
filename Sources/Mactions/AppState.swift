import AppKit
import MactionsCore
import SwiftUI

/// One row in the live runner list: which repo a runner belongs to + its state.
struct FleetRunnerRow: Identifiable {
  let repoFullName: String
  let runner: ManagedRunner
  var id: String { "\(repoFullName)#\(runner.id)" }
}

/// The app's single source of truth. Owns auth + config, drives one
/// `RunnerOrchestrator` per selected repo, and republishes to SwiftUI. A
/// singleton so the `AppDelegate` can reach it during termination.
@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  // Config (persisted to UserDefaults).
  @Published var selectedRepos: [RepoRef] = []
  @Published var labelsText = "self-hosted,macOS,mactions"
  @Published var runnersPerRepo = 1
  /// OAuth App client id for device-flow sign-in. Optional.
  @Published var clientId = ""

  // Repo discovery (for the searchable picker).
  @Published var availableRepos: [RepoRef] = []
  @Published var reposLoading = false

  // Auth.
  @Published var isSignedIn = false
  @Published var authBusy = false
  @Published var pendingDeviceCode: GitHubAuth.DeviceCode?

  // Fleet runtime.
  @Published var state: FleetState = .offline
  @Published var runners: [FleetRunnerRow] = []
  @Published var statusMessage: String?

  /// One orchestrator per repo, keyed by `owner/name`.
  private var orchestrators: [String: RunnerOrchestrator] = [:]
  private let defaults = UserDefaults.standard

  init() {
    selectedRepos = (defaults.stringArray(forKey: "selectedRepos") ?? []).compactMap(RepoRef.init(fullName:))
    labelsText = defaults.string(forKey: "labels") ?? labelsText
    runnersPerRepo = max(1, defaults.integer(forKey: "runnersPerRepo"))
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
    defaults.set(selectedRepos.map(\.fullName), forKey: "selectedRepos")
    defaults.set(labelsText, forKey: "labels")
    defaults.set(runnersPerRepo, forKey: "runnersPerRepo")
    defaults.set(clientId, forKey: "clientId")
  }

  var labels: [String] {
    labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  func isSelected(_ repo: RepoRef) -> Bool { selectedRepos.contains(repo) }

  func toggleRepo(_ repo: RepoRef) {
    guard state == .offline else { return }
    if let index = selectedRepos.firstIndex(of: repo) {
      selectedRepos.remove(at: index)
    } else {
      selectedRepos.append(repo)
    }
    saveConfig()
  }

  // MARK: Auth

  var gitHubCLIAvailable: Bool { GitHubCLIAuth.isAvailable() }

  func signInWithGitHubCLI() {
    do {
      let token = try GitHubCLIAuth.currentToken()
      try TokenStore.save(token)
      isSignedIn = true
      statusMessage = "Signed in via GitHub CLI."
      Task { await loadRepos() }
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
        await loadRepos()
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
      Task { await loadRepos() }
    } catch {
      statusMessage = "Couldn't store the token: \(error)"
    }
  }

  func signOut() {
    Task { await goOfflineAndWait() }
    try? TokenStore.clear()
    isSignedIn = false
    availableRepos = []
    statusMessage = "Signed out."
  }

  // MARK: Repo discovery

  func loadReposIfNeeded() async {
    guard isSignedIn, availableRepos.isEmpty, !reposLoading else { return }
    await loadRepos()
  }

  func loadRepos() async {
    guard let token = TokenStore.load() else { return }
    reposLoading = true
    defer { reposLoading = false }
    do {
      let repos = try await GitHubRepoLister(token: token).listAdminRepos()
      availableRepos = repos
      // Drop any persisted selection the account can no longer admin.
      let admin = Set(repos)
      selectedRepos = selectedRepos.filter { admin.contains($0) }
      if repos.isEmpty {
        statusMessage = "No repos you can administer were found for this account."
      }
    } catch {
      statusMessage = "Couldn't load repos: \(error)"
    }
  }

  // MARK: Fleet

  func toggleOnline() {
    state == .offline ? goOnline() : goOffline()
  }

  func goOnline() {
    guard let token = TokenStore.load() else { statusMessage = "Sign in first."; return }
    guard !selectedRepos.isEmpty else { statusMessage = "Pick at least one repository."; return }
    saveConfig()
    HostCleanup.sweepOrphans()
    state = .starting
    statusMessage = "Preparing runner agent…"
    let repos = selectedRepos
    Task {
      do {
        let template = try await RunnerInstaller.ensureInstalled(token: token)
        let factory = LocalProcessProviderFactory(
          templateDirectory: template, runsRoot: HostCleanup.runsRoot())
        for repo in repos {
          let client = GitHubClient(owner: repo.owner, repo: repo.name, token: token)
          let fleet = FleetConfig(
            owner: repo.owner, repo: repo.name, labels: labels, desiredCount: runnersPerRepo)
          let orch = RunnerOrchestrator(controlPlane: client, factory: factory, config: fleet)
          orch.onChange = { [weak self] in self?.sync() }
          orchestrators[repo.fullName] = orch
          await orch.start()
        }
        state = .online
        sync()
        statusMessage = "Online for \(repos.count) repo\(repos.count == 1 ? "" : "s")."
      } catch {
        statusMessage = "Failed to start: \(error)"
        state = .offline
      }
    }
  }

  func goOffline() {
    Task { await goOfflineAndWait() }
  }

  func goOfflineAndWait() async {
    guard !orchestrators.isEmpty || state != .offline else { return }
    state = .stopping
    sync()
    for orch in orchestrators.values { await orch.stop() }
    orchestrators.removeAll()
    // Each run wipes its own working copy; sweep again defensively.
    HostCleanup.purgeRuns()
    runners = []
    state = .offline
    statusMessage = "Offline."
  }

  /// Remove everything Mactions wrote to disk (cached agent + run files).
  func cleanUpHostFiles() {
    guard state == .offline else { statusMessage = "Go offline first."; return }
    HostCleanup.purgeAll()
    statusMessage = "Removed the cached agent and all run files."
  }

  private func sync() {
    var rows: [FleetRunnerRow] = []
    for (fullName, orch) in orchestrators {
      if let err = orch.lastError { statusMessage = err }
      for runner in orch.runners {
        rows.append(FleetRunnerRow(repoFullName: fullName, runner: runner))
      }
    }
    runners = rows.sorted { $0.id < $1.id }
  }
}
