import XCTest

@testable import MactionsCore

/// Pins the PURE phase parser that drives the live setup stepper: real
/// `prepare-windows-image` / `fusion-windows-base` output lines must map to the
/// right step, advance monotonically across a run, and never regress.
final class WindowsSetupProgressTests: XCTestCase {

  func testMapsRealMarkersToSteps() {
    let cases: [(String, WindowsSetupStep)] = [
      ("==> Resolving the latest stable GA Windows 11 ARM64 build from UUP dump", .downloadISO),
      ("==> Fetching the UUP download package + converting to ISO (multi-GB; resumes if interrupted)", .downloadISO),
      ("==> Reusing cached Win11 ISO for build 26200.8524 (resumed — skipping the ~8 GB download/convert)", .downloadISO),
      ("==> Built ISO: /tmp/x.iso", .downloadISO),
      ("==> Building unattended-install ISO (autounattend.xml + bootstrap.ps1)", .buildMedia),
      ("==> Stashing unattend ISO at the canonical path for the Fusion base build", .buildMedia),
      ("==> Preparing the Win11 boot ISO (no-prompt remaster so there's no boot keypress)", .buildMedia),
      // Resumed run reusing the cached no-prompt boot ISO (prepare-windows-image:461).
      ("==> Reusing the cached no-prompt Win11 ISO for build 26200.8524 (resumed)", .buildMedia),
      ("==> Running VMware Fusion headless base build (autounattend -> bootstrap -> snapshot)", .installWindows),
      ("==> Creating 64 GB disk: /Users/x/.mactions/fusion/win11-runner-base.vmdk", .installWindows),
      ("==> Authoring /Users/x/.mactions/fusion/win11-runner-base.vmx", .installWindows),
      ("==> Booting headless for the unattended install (no keypress — no-prompt ISO)", .installWindows),
      ("    [ 742s] still running (provisioned=0)...", .installWindows),
      ("    [ 900s] provisioning sentinel present — bootstrap completed", .installWindows),
      ("==> Backing up prior base VM 'win11-runner-base' before rebuild", .installWindows),
      ("==> Guest powered off after 1820s — provisioning verified, install + bootstrap done", .finalize),
      ("==> Snapshotting the provisioned base as 'base-provisioned' (the linked-clone parent)", .finalize),
      ("==> Base image ready:", .finalize),
      ("==> Fusion base build done. Base lives at ~/.mactions/fusion/win11-runner-base.vmx", .finalize),
    ]
    for (line, expected) in cases {
      XCTAssertEqual(WindowsSetupProgress.step(for: line), expected, "wrong step for: \(line)")
    }
  }

  func testNonMarkerLinesReturnNil() {
    XCTAssertNil(WindowsSetupProgress.step(for: ""))
    XCTAssertNil(WindowsSetupProgress.step(for: "some random aria2 log line"))
    XCTAssertNil(WindowsSetupProgress.step(for: "    extracting payload..."))
  }

  /// A realistic ordered transcript must never make the (forward-only) stepper
  /// regress, and must end at `.finalize`.
  func testStepsAreMonotonicAcrossARun() {
    let transcript = [
      "==> Resolving the latest stable GA Windows 11 ARM64 build from UUP dump",
      "    build 26200.8524  (uuid abc)",
      "==> Fetching the UUP download package + converting to ISO (multi-GB; resumes if interrupted)",
      "==> Built ISO: /tmp/x.iso",
      "==> Building unattended-install ISO (autounattend.xml + bootstrap.ps1)",
      "==> Stashing unattend ISO at the canonical path for the Fusion base build",
      "==> Preparing the Win11 boot ISO (no-prompt remaster so there's no boot keypress)",
      "==> Running VMware Fusion headless base build (autounattend -> bootstrap -> snapshot)",
      "==> Creating 64 GB disk: /x.vmdk",
      "==> Authoring /x.vmx",
      "==> Booting headless for the unattended install (no keypress — no-prompt ISO)",
      "    [  30s] still running (provisioned=0)...",
      "    [ 900s] provisioning sentinel present — bootstrap completed",
      "==> Guest powered off after 920s — provisioning verified, install + bootstrap done",
      "==> Snapshotting the provisioned base as 'base-provisioned' (the linked-clone parent)",
      "==> Base image ready:",
    ]
    var maxStep = WindowsSetupStep.prerequisites
    for line in transcript {
      guard let step = WindowsSetupProgress.step(for: line) else { continue }
      XCTAssertGreaterThanOrEqual(step, maxStep, "step regressed at: \(line)")
      maxStep = Swift.max(maxStep, step)
    }
    XCTAssertEqual(maxStep, .finalize)
  }

  func testDetailSurfacesInstallTicksAndMilestones() {
    XCTAssertEqual(
      WindowsSetupProgress.detail(for: "    [ 742s] still running (provisioned=0)..."),
      "Installing… (12m elapsed)")
    XCTAssertEqual(
      WindowsSetupProgress.detail(for: "    [  45s] still running (provisioned=1)..."),
      "Installing… (45s elapsed)")
    // Exact strings the scripts emit (prepare-windows-image:268 + :461), so a
    // future wording drift in the real markers fails these tests.
    XCTAssertEqual(
      WindowsSetupProgress.detail(
        for: "==> Reusing cached Win11 ISO for build 26200.8524 (resumed — skipping the ~8 GB download/convert)"),
      "Reusing the cached ISO from the last attempt (resumed).")
    XCTAssertEqual(
      WindowsSetupProgress.detail(for: "==> Reusing the cached no-prompt Win11 ISO for build 26200.8524 (resumed)"),
      "Reusing the cached boot ISO (resumed).")
    XCTAssertNil(WindowsSetupProgress.detail(for: "==> Authoring /x.vmx"))  // no detail for this one
  }

  func testDurationHelpers() {
    XCTAssertEqual(WindowsSetupProgress.firstBracketedSeconds(in: "    [ 742s] still running"), 742)
    XCTAssertEqual(WindowsSetupProgress.firstBracketedSeconds(in: "no bracket here"), nil)
    XCTAssertEqual(WindowsSetupProgress.humanDuration(45), "45s")
    XCTAssertEqual(WindowsSetupProgress.humanDuration(742), "12m")
    XCTAssertEqual(WindowsSetupProgress.humanDuration(3700), "1h 1m")
  }

  func testStepOrderingAndCoverage() {
    XCTAssertEqual(WindowsSetupStep.allCases.count, 5)
    XCTAssertTrue(WindowsSetupStep.prerequisites < WindowsSetupStep.finalize)
    XCTAssertEqual(Swift.max(WindowsSetupStep.downloadISO, WindowsSetupStep.buildMedia), .buildMedia)
  }

  /// The transient/external classifier (drives the "not your setup — safe to
  /// retry" hint): a network/upstream failure reads transient; a genuine LOCAL
  /// failure must NOT, or we'd wrongly tell the user it isn't their problem.
  func testTransientFailureClassifier() {
    // The actual field failure: git.uupdump.net returned 522 on a converter file.
    XCTAssertTrue(WindowsSetupProgress.isLikelyTransientFailure(
      "ERROR CUID#8 - Download aborted. URI=https://git.uupdump.net/x/convert_ve_plugin\nstatus=522\nerror: ISO conversion failed"))
    XCTAssertTrue(WindowsSetupProgress.isLikelyTransientFailure(
      "error: ISO conversion failed after 3 attempts (see output above)."))
    XCTAssertTrue(WindowsSetupProgress.isLikelyTransientFailure("couldn't reach the UUP dump API after retries"))
    XCTAssertTrue(WindowsSetupProgress.isLikelyTransientFailure("curl: (6) Could not resolve host: api.uupdump.net"))
    // The flaky OOBE handoff stall (fusion-windows-base's Tools-up watchdog): safe to retry.
    XCTAssertTrue(WindowsSetupProgress.isLikelyTransientFailure(
      "error: guest stuck after 2400s — VMware Tools never came up, so the unattended Windows Setup/OOBE handoff (autounattend.xml) never reached bootstrap.ps1. This is the flaky Win11-ARM OOBE handoff, not your Mac or config; it is safe to retry."))
    // Genuine LOCAL failures: must read as NOT transient.
    XCTAssertFalse(WindowsSetupProgress.isLikelyTransientFailure(
      "VMware Fusion isn't installed. Get it free from the Broadcom portal, then try again."))
    XCTAssertFalse(WindowsSetupProgress.isLikelyTransientFailure("auto-download needs these tools first: aria2"))
    XCTAssertFalse(WindowsSetupProgress.isLikelyTransientFailure("converter finished but produced no ISO in /tmp"))
    // The new git/bash/pwsh verification failure is LOCAL (a broken build), NOT transient.
    XCTAssertFalse(WindowsSetupProgress.isLikelyTransientFailure(
      "REQUIRED runner tools missing after provisioning: git (C:\\Git\\cmd\\git.exe)"))
  }
}

/// Pins `Shell.runStreaming`: lines are emitted as they arrive (incl. an
/// unterminated trailing line), and the full transcript is still captured.
final class ShellStreamingTests: XCTestCase {

  /// Thread-safe sink for the streamed lines (the callback is `@Sendable`, called
  /// from background drain threads — a plain captured `var` won't compile under
  /// Swift 6 strict concurrency).
  private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
  }

  func testStreamsLinesAndCapturesStdout() throws {
    let sink = Sink()
    let result = try Shell.runStreaming("/bin/sh", ["-c", "printf 'one\\ntwo\\nthree'"]) {
      sink.add($0)
    }
    XCTAssertTrue(result.ok)
    // Full transcript retained (no trailing newline on 'three').
    XCTAssertEqual(result.stdout, "one\ntwo\nthree")
    // 'three' has no trailing newline → delivered via the EOF flush.
    XCTAssertEqual(sink.all, ["one", "two", "three"])
  }

  func testCapturesStdoutAndStderrSeparately() throws {
    let result = try Shell.runStreaming(
      "/bin/sh", ["-c", "printf 'out\\n'; printf 'err\\n' 1>&2"]
    ) { _ in }
    XCTAssertEqual(result.stdout, "out\n")
    XCTAssertEqual(result.stderr, "err\n")
  }

  func testReportsNonZeroExitStatus() throws {
    let result = try Shell.runStreaming("/bin/sh", ["-c", "exit 3"]) { _ in }
    XCTAssertEqual(result.status, 3)
    XCTAssertFalse(result.ok)
  }
}
