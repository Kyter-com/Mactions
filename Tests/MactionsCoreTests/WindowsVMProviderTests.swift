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
    // The free-first alias is identical with a single backend.
    XCTAssertEqual(
      WindowsVMProviderFactory.detectFreeFirstCLI() is VMwareCLI,
      cli is VMwareCLI)
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
