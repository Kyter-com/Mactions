import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Windows prerequisite preflight:
/// detection assembly + the brew-command builder. No shelling out, no real
/// `brew`/Fusion, no network. VMware Fusion is the sole backend and is a MANUAL
/// (non-brew) install, so the plan only ever installs the free brew-able tools
/// (UUP-dump converters + xorriso) — never a hypervisor.
final class WindowsPreflightTests: XCTestCase {

  // Build a report from a set of "installed" tool names via the injectable
  // probes. `whichHits` covers PATH/Homebrew bins; `pathHits` covers absolute
  // paths (Fusion's vmrun + the brew prefixes).
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

  func testDetectsVMwareFusionInsideAppBundleNotOnPath() {
    // vmrun ships inside VMware Fusion.app, never on PATH — probed by abs path.
    let r = report(paths: [WindowsPreflight.vmrunPath])
    XCTAssertTrue(r.fusionInstalled)
    XCTAssertTrue(r.hasHypervisor)
    XCTAssertEqual(r.recommendedBackend, .vmwareFusion)
    XCTAssertTrue(WindowsPreflight.Hypervisor.vmwareFusion.isFree)  // free since Nov 2024
  }

  func testFusionAbsentMeansNoBackend() {
    let r = report(which: ["brew"])  // brew but no vmrun
    XCTAssertFalse(r.fusionInstalled)
    XCTAssertFalse(r.hasHypervisor)
    XCTAssertNil(r.recommendedBackend)
  }

  func testFusionNotReadyWhenLifecycleHelperMissingEvenIfVmrunPresent() {
    // The LIVE backend gate (detectInstalledCLI) needs BOTH vmrun AND the
    // mactions-fusion-vm helper. With vmrun present but the helper missing
    // (e.g. a packaged app without the bundled scripts), the checklist must NOT
    // report Fusion ready — or "ready" would contradict what can actually start.
    let notReady = WindowsPreflight.makeReport(
      whichLookup: { _ in nil },
      isExecutable: { $0 == WindowsPreflight.vmrunPath },
      fusionHelperPresent: false)
    XCTAssertFalse(notReady.fusionInstalled)
    XCTAssertFalse(notReady.hasHypervisor)
    XCTAssertNil(notReady.recommendedBackend)
    // With the helper present, the same vmrun signal DOES read as installed.
    let ready = WindowsPreflight.makeReport(
      whichLookup: { _ in nil },
      isExecutable: { $0 == WindowsPreflight.vmrunPath },
      fusionHelperPresent: true)
    XCTAssertTrue(ready.fusionInstalled)
  }

  func testConvertersMapMissingBinariesToBrewFormulae() {
    // Binary→formula differs for most: wimlib-imagex→wimlib, mkisofs→cdrtools,
    // chntpw→its tap. Only the absent ones are reported, as install args.
    let r = report(which: ["aria2c", "cabextract"])
    XCTAssertEqual(r.missingConverterFormulae, ["wimlib", "cdrtools", "minacle/chntpw/chntpw"])
    let allPresent = report(which: Set(WindowsImage.converterDependencies.map(\.binary)))
    XCTAssertTrue(allPresent.missingConverterFormulae.isEmpty)
  }

  func testMissingFreeFormulaeIncludesXorriso() {
    // xorriso (for the no-prompt boot ISO) is brew-able and folded into the free
    // install list — but is NOT required for `ready` (the build falls back).
    let r = report(which: Set(WindowsImage.converterDependencies.map(\.binary)))  // converters present, no xorriso
    XCTAssertTrue(r.missingConverterFormulae.isEmpty)
    XCTAssertFalse(r.xorrisoInstalled)
    XCTAssertEqual(r.missingFreeFormulae, ["xorriso"])
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

  func testInstallPlanInstallsMissingConvertersAndXorrisoWhenBrewPresent() {
    // brew present, nothing else -> install all converter tools + xorriso in one
    // command. NEVER a hypervisor (Fusion is a manual Broadcom-portal download).
    let plan = WindowsPreflight.installPlan(for: report(which: ["brew"]))
    guard case let .install(commands) = plan else {
      return XCTFail("expected .install, got \(plan)")
    }
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands[0].executable, "/opt/homebrew/bin/brew")
    XCTAssertEqual(
      commands[0].arguments,
      ["install", "aria2", "cabextract", "wimlib", "cdrtools", "minacle/chntpw/chntpw", "xorriso"])
    // No hypervisor formula/cask is ever planned.
    XCTAssertFalse(commands.contains { $0.arguments.contains("--cask") })
    XCTAssertFalse(commands.contains { $0.arguments.contains("qemu") })
    XCTAssertFalse(commands.contains { $0.arguments.contains("parallels") })
  }

  func testInstallPlanOnlyXorrisoWhenConvertersPresent() {
    // Converters all present but xorriso missing -> install just xorriso.
    let r = report(which: Set(["brew"] + WindowsImage.converterDependencies.map(\.binary)))
    let plan = WindowsPreflight.installPlan(for: r)
    guard case let .install(commands) = plan else {
      return XCTFail("expected .install, got \(plan)")
    }
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands[0].arguments, ["install", "xorriso"])
  }

  func testInstallPlanNothingToInstallWhenEverythingPresent() {
    let everything = report(
      which: Set(["brew", "xorriso"] + WindowsImage.converterDependencies.map(\.binary)),
      paths: [WindowsPreflight.vmrunPath])
    XCTAssertTrue(everything.ready)
    XCTAssertEqual(WindowsPreflight.installPlan(for: everything), .nothingToInstall)
  }

  func testReadyDoesNotRequireXorriso() {
    // Fusion + brew + converters present, xorriso absent -> still "ready" (the
    // no-prompt ISO gracefully falls back to a one-keypress prompting ISO).
    let r = report(
      which: Set(["brew"] + WindowsImage.converterDependencies.map(\.binary)),
      paths: [WindowsPreflight.vmrunPath])
    XCTAssertFalse(r.xorrisoInstalled)
    XCTAssertTrue(r.ready)
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

  func testRunInstallRunsThePlannedCommandOnSuccess() {
    var ran: [[String]] = []
    let result = WindowsPreflight.runInstall(for: report(which: ["brew"])) { cmd in
      ran.append(cmd.arguments)
      return (0, "")
    }
    XCTAssertEqual(result, .installed)
    XCTAssertEqual(ran, [
      ["install", "aria2", "cabextract", "wimlib", "cdrtools", "minacle/chntpw/chntpw", "xorriso"],
    ])
  }
}
