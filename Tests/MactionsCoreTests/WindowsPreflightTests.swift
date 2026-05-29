import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Windows prerequisite preflight:
/// detection assembly, the brew-command builder, free-first backend selection,
/// and the missing-Homebrew path. No shelling out, no real `brew`/UTM, no
/// network — these pin the install command shapes + the free-first policy the
/// same way `WindowsImageTests` pins the UUP-dump logic.
final class WindowsPreflightTests: XCTestCase {

  // Build a report from a set of "installed" tool names via the injectable
  // probes. `whichHits` covers PATH/Homebrew bins; `pathHits` covers absolute
  // paths (UTM's utmctl + the two brew prefixes).
  private func report(
    which whichHits: Set<String> = [],
    paths pathHits: Set<String> = []
  ) -> WindowsPreflight.Report {
    WindowsPreflight.makeReport(
      whichLookup: { whichHits.contains($0) ? "/opt/homebrew/bin/\($0)" : nil },
      isExecutable: { pathHits.contains($0) }
    )
  }

  // MARK: Detection assembly

  func testDetectsBrewViaWhich() {
    let r = report(which: ["brew"])
    XCTAssertTrue(r.homebrewInstalled)
    XCTAssertEqual(r.homebrew.path, "/opt/homebrew/bin/brew")
  }

  func testDetectsBrewViaWellKnownPrefixWhenNotOnPath() {
    // A Finder-launched GUI app may not have brew on its inherited PATH, so we
    // also probe /opt/homebrew/bin/brew and /usr/local/bin/brew directly.
    let r = report(paths: ["/usr/local/bin/brew"])
    XCTAssertTrue(r.homebrewInstalled)
    XCTAssertEqual(r.homebrew.path, "/usr/local/bin/brew")
  }

  func testDetectsUTMInsideAppBundleNotOnPath() {
    // utmctl ships inside UTM.app, never on PATH — must be probed by abs path.
    let r = report(paths: [WindowsPreflight.utmctlPath])
    XCTAssertEqual(r.hypervisors[.utm]?.installed, true)
    XCTAssertEqual(r.installedHypervisors, [.utm])
    XCTAssertTrue(r.hasHypervisor)
  }

  func testDetectsParallelsAndQemuViaWhich() {
    let r = report(which: ["prlctl", "qemu-system-aarch64"])
    XCTAssertEqual(r.hypervisors[.parallels]?.installed, true)
    XCTAssertEqual(r.hypervisors[.qemu]?.installed, true)
    XCTAssertEqual(r.hypervisors[.utm]?.installed, false)
    // Free-first iteration order is preserved (utm absent → parallels, qemu).
    XCTAssertEqual(r.installedHypervisors, [.parallels, .qemu])
  }

  func testConvertersMapMissingBinariesToBrewFormulae() {
    // wimlib-imagex binary -> wimlib formula; only the absent ones are reported.
    let r = report(which: ["aria2c", "cabextract"])
    XCTAssertEqual(r.missingConverterFormulae, ["wimlib", "chntpw"])
    let allPresent = report(which: Set(WindowsImage.converterDependencies))
    XCTAssertTrue(allPresent.missingConverterFormulae.isEmpty)
  }

  // MARK: Free-first backend selection

  func testRecommendedBackendPrefersFreeUTM() {
    // Both UTM (free) and Parallels (paid) present -> recommend UTM.
    let r = report(which: ["prlctl"], paths: [WindowsPreflight.utmctlPath])
    XCTAssertEqual(r.recommendedBackend, .utm)
  }

  func testRecommendedBackendUsesParallelsOnlyWhenItsTheOnlyOne() {
    // Parallels is paid, but if it's the ONLY hypervisor present we use it
    // (never install it, but honor an existing license).
    let r = report(which: ["prlctl"])
    XCTAssertEqual(r.recommendedBackend, .parallels)
  }

  func testRecommendedBackendFallsBackToQemu() {
    let r = report(which: ["qemu-system-aarch64"])
    XCTAssertEqual(r.recommendedBackend, .qemu)
  }

  func testRecommendedBackendNilWhenNonePresent() {
    XCTAssertNil(report().recommendedBackend)
    // The free backend we'd offer to INSTALL is always UTM (never Parallels).
    XCTAssertEqual(WindowsPreflight.Report.recommendedFreeBackendToInstall, .utm)
    XCTAssertTrue(WindowsPreflight.Report.recommendedFreeBackendToInstall.isFree)
    XCTAssertFalse(WindowsPreflight.Hypervisor.parallels.isFree)
  }

  // MARK: Install plan (the pure brew-command builder)

  func testInstallPlanReportsHomebrewMissingAndNeverAutoInstallsIt() {
    // No brew at all -> we DO NOT try to install Homebrew; we point at brew.sh.
    let plan = WindowsPreflight.installPlan(for: report())
    guard case let .homebrewMissing(message) = plan else {
      return XCTFail("expected .homebrewMissing, got \(plan)")
    }
    XCTAssertTrue(message.contains("https://brew.sh"))
  }

  func testInstallPlanInstallsUTMCaskAndMissingConvertersWhenBrewPresent() {
    // brew present, nothing else -> add the free UTM cask + all converter tools.
    let plan = WindowsPreflight.installPlan(for: report(which: ["brew"]))
    guard case let .install(commands) = plan else {
      return XCTFail("expected .install, got \(plan)")
    }
    XCTAssertEqual(commands.count, 2)
    XCTAssertEqual(commands[0].executable, "/opt/homebrew/bin/brew")
    XCTAssertEqual(commands[0].arguments, ["install", "--cask", "utm"])
    XCTAssertEqual(
      commands[1].arguments, ["install", "aria2c", "cabextract", "wimlib", "chntpw"])
  }

  func testInstallPlanNeverInstallsParallelsAndSkipsHypervisorWhenOnePresent() {
    // Parallels already present (paid). We must NOT add a hypervisor cask and
    // must NEVER emit a `--cask parallels`. Only the missing converters install.
    let plan = WindowsPreflight.installPlan(
      for: report(which: ["brew", "prlctl", "aria2c", "cabextract", "wimlib-imagex"]))
    guard case let .install(commands) = plan else {
      return XCTFail("expected .install, got \(plan)")
    }
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands[0].arguments, ["install", "chntpw"])
    XCTAssertFalse(
      commands.contains { $0.arguments.contains("parallels") },
      "must never plan to install paid Parallels")
  }

  func testInstallPlanSkipsUTMCaskWhenAFreeHypervisorAlreadyPresent() {
    // UTM already present -> no hypervisor cask; just the missing converters.
    let plan = WindowsPreflight.installPlan(
      for: report(which: ["brew"], paths: [WindowsPreflight.utmctlPath]))
    guard case let .install(commands) = plan else {
      return XCTFail("expected .install, got \(plan)")
    }
    XCTAssertFalse(commands.contains { $0.arguments.contains("--cask") })
    XCTAssertEqual(commands.first?.arguments.first, "install")
  }

  func testInstallPlanNothingToInstallWhenEverythingPresent() {
    let everything = report(
      which: Set(["brew", "prlctl"] + WindowsImage.converterDependencies))
    XCTAssertTrue(everything.ready)
    XCTAssertEqual(WindowsPreflight.installPlan(for: everything), .nothingToInstall)
  }

  // MARK: runInstall accounting (with an injected runner — no shelling out)

  func testRunInstallReturnsHomebrewMissingWithoutRunningAnything() {
    var ran = 0
    let result = WindowsPreflight.runInstall(for: report()) { _ in
      ran += 1
      return (0, "")
    }
    XCTAssertEqual(ran, 0, "must not run any brew command when Homebrew is absent")
    guard case let .homebrewMissing(message) = result else {
      return XCTFail("expected .homebrewMissing, got \(result)")
    }
    XCTAssertTrue(message.contains("https://brew.sh"))
  }

  func testRunInstallRunsEveryPlannedCommandOnSuccess() {
    var ran: [[String]] = []
    let result = WindowsPreflight.runInstall(for: report(which: ["brew"])) { cmd in
      ran.append(cmd.arguments)
      return (0, "")
    }
    XCTAssertEqual(result, .installed)
    XCTAssertEqual(ran, [
      ["install", "--cask", "utm"],
      ["install", "aria2c", "cabextract", "wimlib", "chntpw"],
    ])
  }

  func testRunInstallStopsAtFirstFailureAndReportsIt() {
    var ran = 0
    let result = WindowsPreflight.runInstall(for: report(which: ["brew"])) { _ in
      ran += 1
      return (1, "  brew: download failed\n")
    }
    XCTAssertEqual(ran, 1, "must stop at the first failing command")
    guard case let .failed(command, stderr) = result else {
      return XCTFail("expected .failed, got \(result)")
    }
    XCTAssertTrue(command.contains("install --cask utm"))
    XCTAssertEqual(stderr, "brew: download failed")  // trimmed
  }

  func testRunInstallTreatsUnlaunchableCommandAsFailure() {
    let result = WindowsPreflight.runInstall(for: report(which: ["brew"])) { _ in
      (nil, "could not launch")  // nil status == couldn't launch the process
    }
    guard case .failed = result else {
      return XCTFail("expected .failed, got \(result)")
    }
  }

  func testRunInstallNothingToInstallWhenAllPresent() {
    let everything = report(
      which: Set(["brew", "prlctl"] + WindowsImage.converterDependencies))
    let result = WindowsPreflight.runInstall(for: everything) { _ in
      XCTFail("should not run any command")
      return (0, "")
    }
    XCTAssertEqual(result, .nothingToInstall)
  }
}
