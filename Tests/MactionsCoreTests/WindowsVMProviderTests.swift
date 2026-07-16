import XCTest

@testable import MactionsCore

/// Unit tests for the *pure* logic of the Windows VM provider: command/argument
/// construction, the per-clone config-ISO + injection plan, the power-state
/// completion classifier, and clone-name extraction. These do NOT boot a VM
/// (none is available in CI / on the dev host) — they pin the shapes the
/// provider hands to the `mactions-fusion-vm` helper / `hdiutil`. VMware Fusion
/// (`VMwareCLI`) is the sole backend.
final class WindowsVMProviderTests: XCTestCase {

  // MARK: Per-clone config ISO (the headless JIT-delivery payload)

  func testConfigISOArgsFlagOrder() {
    XCTAssertEqual(
      WindowsImage.configISOArgs(sourceDir: "/tmp/stage", output: "/tmp/config.iso"),
      ["makehybrid", "-iso", "-joliet", "-ov", "-default-volume-name", "MACTIONS", "-o", "/tmp/config.iso", "/tmp/stage"])
    // Custom volume name flows through (right after -default-volume-name).
    XCTAssertEqual(
      WindowsImage.configISOArgs(sourceDir: "/s", output: "/o.iso", volumeName: "MX"),
      ["makehybrid", "-iso", "-joliet", "-ov", "-default-volume-name", "MX", "-o", "/o.iso", "/s"])
  }

  // MARK: VMware Fusion (mactions-fusion-vm helper) verb shapes + injection

  func testVMwareCLIVerbShapes() {
    // Every verb is `<helper> <verb> <clone>` — the helper owns the vmrun
    // clone/start/stop/deleteVM orchestration; Swift only pins the arg shapes.
    let cli = VMwareCLI(executable: "/repo/scripts/mactions-fusion-vm",
                        clonesDir: "/state/fusion")
    XCTAssertEqual(cli.cloneArgs(base: "win11-runner-base", clone: "mactions-abc"),
      ["clone", "win11-runner-base", "mactions-abc"])
    XCTAssertEqual(cli.startArgs(clone: "mactions-abc"), ["start", "mactions-abc"])
    XCTAssertEqual(cli.stopArgs(clone: "mactions-abc"), ["stop", "mactions-abc"])
    XCTAssertEqual(cli.forceStopArgs(clone: "mactions-abc"), ["stop", "mactions-abc"])
    XCTAssertEqual(cli.deleteArgs(clone: "mactions-abc"), ["delete", "mactions-abc"])
    XCTAssertEqual(cli.statusArgs(clone: "mactions-abc"), ["status", "mactions-abc"])
    XCTAssertEqual(cli.guestOutcomeArgs(clone: "mactions-abc"), ["outcome", "mactions-abc"])
    XCTAssertEqual(
      cli.deliverJITArgs(clone: "mactions-abc", source: "/tmp/jitconfig"),
      ["deliver-jit", "mactions-abc", "/tmp/jitconfig"])
    XCTAssertEqual(
      cli.captureGuestLogArgs(clone: "mactions-abc", destination: "/logs/run.log"),
      ["capture-log", "mactions-abc", "/logs/run.log"])
    XCTAssertEqual(cli.baseStatusArgs(base: "win11-runner-base"), ["base-status", "win11-runner-base"])
    XCTAssertTrue(cli.displayName.contains("VMware Fusion"))
  }

  func testVMwareInjectionCopiesConfigFileIntoCloneDir() {
    // The helper's `clone` step already wired the clone's sata0:0 CD to
    // <clone-dir>/config.iso, so injection is a plain copy to that path.
    let cli = VMwareCLI(executable: "/repo/scripts/mactions-fusion-vm",
                        clonesDir: "/state/fusion")
    XCTAssertEqual(cli.cloneBundlePath(clone: "mactions-abc"), "/state/fusion/mactions-abc")
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: nil, configISO: "/tmp/c.iso"),
      .copyConfigFile(target: "/state/fusion/mactions-abc/config.iso"))
    XCTAssertEqual(
      cli.injectionPlan(clone: "mactions-abc", clonePath: "/elsewhere", configISO: "/tmp/c.iso"),
      .copyConfigFile(target: "/elsewhere/config.iso"))
  }

  func testVMwareStatusParserMapsHelperOutputs() {
    // Helper normalizes to exactly "running"/"stopped" (vmrun has no getstate);
    // base-status adds "in-use"/"no-snapshot"/"missing" — only "stopped" is ready.
    let cli = VMwareCLI(executable: "/x", clonesDir: "/y")
    XCTAssertTrue(cli.parseIsStopped(from: "stopped"))
    XCTAssertTrue(cli.parseIsStopped(from: "stopped\n"))
    XCTAssertFalse(cli.parseIsStopped(from: "running"))
    XCTAssertFalse(cli.parseIsStopped(from: "in-use"))
    XCTAssertFalse(cli.parseIsStopped(from: "no-snapshot"))
    XCTAssertFalse(cli.parseIsStopped(from: "missing"))
    XCTAssertFalse(cli.parseIsStopped(from: ""))
  }

  func testGuestOutcomeParserRejectsPowerOffWithoutVerifiedMarker() {
    XCTAssertEqual(WindowsGuestOutcome.parse("success\r\n"), .success)
    XCTAssertEqual(WindowsGuestOutcome.parse("NO-JIT\n"), .noJIT)
    XCTAssertEqual(WindowsGuestOutcome.parse("runner-exit:17\n"), .runnerExit(17))
    XCTAssertEqual(WindowsGuestOutcome.parse("runner-exit:-1"), .runnerExit(-1))
    XCTAssertNil(WindowsGuestOutcome.parse("pending\n"))
    XCTAssertNil(WindowsGuestOutcome.parse("runner-exit:"))
    XCTAssertNil(WindowsGuestOutcome.parse("garbage"))

    XCTAssertEqual(WindowsGuestOutcome.success.exitStatus, 0)
    XCTAssertEqual(WindowsGuestOutcome.noJIT.exitStatus, 1)
    XCTAssertEqual(WindowsGuestOutcome.runnerExit(17).exitStatus, 17)
    // A malformed guest claim of runner-exit:0 must not become a second success
    // spelling; recipe-v14's clean spelling is exactly `success`.
    XCTAssertEqual(WindowsGuestOutcome.runnerExit(0).exitStatus, 1)
  }

  func testFusionHelperCarriesGuestOutcomeAndFailureLogVerbs() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = try String(
      contentsOf: repoRoot.appendingPathComponent("scripts/mactions-fusion-vm"), encoding: .utf8)
    for required in [
      "cmd_outcome()", "fileExistsInGuest", "copyFileFromGuestToHost",
      "cmd_deliver_jit()", "copyFileFromHostToGuest", "GUEST_JIT='C:\\setup\\jitconfig'",
      "cmd_capture_log()", "GUEST_OUTCOME='C:\\setup\\logs\\run-outcome.txt'",
      "GUEST_RUN_LOG='C:\\setup\\logs\\run-job.log'",
    ] {
      XCTAssertTrue(helper.contains(required), "missing guest-diagnostic helper fragment: \(required)")
    }
  }

  func testFusionHelperFallsBackToVMSDForSnapshotDetection() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helperURL = repoRoot.appendingPathComponent("scripts/mactions-fusion-vm")
    guard let helper = try? String(contentsOf: helperURL, encoding: .utf8) else {
      return XCTFail("could not read \(helperURL.path)")
    }

    for required in [
      "vmrun can refuse listSnapshots while a linked clone is running",
      "local vmsd=\"${vmx%.vmx}.vmsd\"",
      "snapshot[0-9]+\\.displayName",
    ] {
      XCTAssertNotNil(
        helper.range(of: required),
        "mactions-fusion-vm is missing snapshot fallback fragment: \(required)")
    }
  }

  // MARK: Power-state completion classifier

  func testPhaseClassifierRequiresRunningBeforeStopped() {
    let p = WindowsVMProvider(id: "abc", baseImage: "base", cli: VMwareCLI(executable: "/x"))
    // 'stopped' (fresh clone or self-powered-off) classifies as .stopped...
    XCTAssertEqual(p.phase(from: "stopped"), .stopped)
    // ...but live/transitional states are .running (so the boot gate passes)...
    XCTAssertEqual(p.phase(from: "started"), .running)
    XCTAssertEqual(p.phase(from: "VM 'x' is running"), .running)
    XCTAssertEqual(p.phase(from: "stopping"), .running)  // mid power-off, NOT yet stopped
    XCTAssertEqual(p.phase(from: "suspended"), .running)
    // ...and an unknown/empty read is .starting (keep polling, don't conclude).
    XCTAssertEqual(p.phase(from: ""), .starting)
    XCTAssertEqual(p.phase(from: "???"), .starting)
  }

  // MARK: Job-timeout parity

  /// The default jobTimeout must cover GitHub's own job-execution allowance
  /// (the `timeout-minutes: 360` default = 6 h) PLUS lifecycle headroom — the
  /// provider clock starts at VM boot, so it also spans registration, the
  /// pre-job idle wait (bounded by the orchestrator's ~8-min idle refresh),
  /// cancellation wind-down, and guest shutdown. Anything ≤ 6 h would
  /// reintroduce issue #37 B12 (a legal full-length job force-killed minutes
  /// before finishing, surfaced as "runner lost communication"); the old 50-min
  /// budget was based on a misread of JIT expiry, which bounds registration,
  /// not job duration. It is a hung-guest watchdog only — never the duration
  /// enforcer (GitHub's timeout-minutes is).
  func testDefaultJobTimeoutCoversHostedSixHourJobLimitWithLifecycleHeadroom() {
    XCTAssertEqual(WindowsVMProvider.defaultJobTimeout, (360 + 30) * 60)
    XCTAssertGreaterThan(WindowsVMProvider.defaultJobTimeout, 360 * 60)
  }

  // MARK: Clone naming + factory

  func testCloneNameCarriesMactionsPrefix() {
    let p = WindowsVMProvider(id: "host-9f2", baseImage: "base", cli: VMwareCLI(executable: "/x"))
    XCTAssertEqual(p.cloneName, "mactions-host-9f2")
  }

  func testFactoryStampsMactionsPrefixedWindowsProvider() {
    let factory = WindowsVMProviderFactory(
      baseImage: "win11-runner-base", cli: VMwareCLI(executable: "/x"))
    let provider = factory.makeProvider(name: "mactions-testmac-abc")
    XCTAssertEqual(provider.id, "mactions-testmac-abc")
    XCTAssertTrue(provider is WindowsVMProvider)
    XCTAssertTrue(factory.kind.contains("Windows VM"))
    XCTAssertTrue(factory.kind.contains("VMware Fusion"))
  }

  func testDetectInstalledCLIReturnsVMwareOrNil() {
    // Fusion is the sole backend: detection returns a VMwareCLI pointing at a
    // real helper when both the helper + vmrun are present, else nil.
    let cli = WindowsVMProviderFactory.detectInstalledCLI()
    if let cli {
      XCTAssertTrue(cli is VMwareCLI)
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: cli.executable),
        "detected CLI must point at a real helper executable")
    } else {
      // Fusion (vmrun) and/or the helper aren't installed on this host.
      XCTAssertNil(cli)
    }
  }

  // MARK: Helper resolution (bundle-aware — the distributed-.app fix)

  func testResolveFusionHelperPrefersBundledResource() {
    // REGRESSION: a downloaded .app ships scripts/ in Contents/Resources/
    // (project.yml's "Bundle scripts/ into Resources" step). Pre-fix resolution
    // tried ONLY cwd / binary-walk-up / #filePath — all of which MISS inside a
    // .app (cwd is "/", the binary sits under Contents/MacOS, #filePath is the
    // CI builder's path), so Fusion read as "not installed" despite vmrun being
    // present. The bundle strategy (0) must win. Inputs model the real bundle.
    let resources = "/Applications/Mactions.app/Contents/Resources"
    let expected = resources + "/scripts/mactions-fusion-vm"
    let resolved = WindowsVMProviderFactory.resolveFusionHelper(
      bundleResourceDir: resources,
      cwd: "/",
      binaryPath: "/Applications/Mactions.app/Contents/MacOS/Mactions",
      sourceFilePath: "/Users/runner/work/Mactions/Mactions/Sources/MactionsCore/WindowsVMProvider.swift",
      isExecutable: { $0 == expected })
    XCTAssertEqual(resolved, expected)
  }

  func testResolveFusionHelperFallsBackToCwdUnderSwiftRun() {
    // Under `swift run` from the repo there's no bundle resource dir; the cwd
    // strategy (1) still resolves, so the fix leaves dev behavior unchanged.
    let expected = "/repo/scripts/mactions-fusion-vm"
    let resolved = WindowsVMProviderFactory.resolveFusionHelper(
      bundleResourceDir: nil,
      cwd: "/repo",
      binaryPath: "/repo/.build/arm64-apple-macosx/debug/Mactions",
      sourceFilePath: "/repo/Sources/MactionsCore/WindowsVMProvider.swift",
      isExecutable: { $0 == expected })
    XCTAssertEqual(resolved, expected)
  }

  func testResolveFusionHelperWalksUpFromBinaryWhenCwdMisses() {
    // `swift run` from an unrelated cwd: walking up from the binary under
    // .build/ reaches the repo root that has scripts/. Strategy (2).
    let expected = "/repo/scripts/mactions-fusion-vm"
    let resolved = WindowsVMProviderFactory.resolveFusionHelper(
      bundleResourceDir: nil,
      cwd: "/some/unrelated/dir",
      binaryPath: "/repo/.build/arm64-apple-macosx/debug/Mactions",
      sourceFilePath: "/nonexistent/WindowsVMProvider.swift",
      isExecutable: { $0 == expected })
    XCTAssertEqual(resolved, expected)
  }

  func testResolveFusionHelperReturnsNilWhenHelperAbsentEverywhere() {
    // No bundle copy, no cwd/binary/source copy → nil (Fusion not offered).
    let resolved = WindowsVMProviderFactory.resolveFusionHelper(
      bundleResourceDir: "/Applications/Mactions.app/Contents/Resources",
      cwd: "/",
      binaryPath: "/Applications/Mactions.app/Contents/MacOS/Mactions",
      sourceFilePath: "/nonexistent/WindowsVMProvider.swift",
      isExecutable: { _ in false })
    XCTAssertNil(resolved)
  }

  // MARK: Teardown guard

  func testStopIsIdempotentAndClearsRunning() {
    // `stop()` tears the clone down via a (here non-existent) CLI path, which is
    // harmless. The `tornDown` guard means a second `stop()` is a safe no-op.
    let p = WindowsVMProvider(
      id: "abc", baseImage: "base",
      cli: VMwareCLI(executable: "/nonexistent/mactions-fusion-vm"),
      stopSettleTimeout: 0.05, stopPollInterval: 0.01)
    XCTAssertFalse(p.isRunning)
    p.stop()
    XCTAssertFalse(p.isRunning)
    p.stop()  // second call must not crash / re-run teardown effects
    XCTAssertFalse(p.isRunning)
  }

  // MARK: Stray-clone reaping (HostCleanup)

  func testWindowsCloneNameExtractionOnlyMatchesOurPrefix() {
    let listing = """
      win11-runner-base
      mactions-host-aaa
      someones-other-vm
      mactions-host-bbb
      Windows 11
      """
    XCTAssertEqual(
      HostCleanup.windowsCloneNames(in: listing),
      ["mactions-host-aaa", "mactions-host-bbb"])
  }
}
