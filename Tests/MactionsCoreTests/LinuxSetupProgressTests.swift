import XCTest

@testable import MactionsCore

/// Pins the pure Linux setup-progress parser (the 2-step stepper) and the
/// transient-failure classifier, mirroring `WindowsSetupProgressTests`.
final class LinuxSetupProgressTests: XCTestCase {

  func testStepsAreOrderedAndForwardOnly() {
    XCTAssertEqual(LinuxSetupStep.allCases, [.verifyDaemon, .pullImage])
    XCTAssertLessThan(LinuxSetupStep.verifyDaemon, LinuxSetupStep.pullImage)
    XCTAssertFalse(LinuxSetupStep.verifyDaemon.title.isEmpty)
    XCTAssertFalse(LinuxSetupStep.pullImage.hint.isEmpty)
  }

  func testStepForLineMapsPullMarkers() {
    XCTAssertEqual(LinuxSetupProgress.step(for: "latest: Pulling from actions/actions-runner"), .pullImage)
    XCTAssertEqual(LinuxSetupProgress.step(for: "a1b2: Pull complete"), .pullImage)
    XCTAssertEqual(LinuxSetupProgress.step(for: "Downloading [====>   ] 40MB/120MB"), .pullImage)
    XCTAssertEqual(LinuxSetupProgress.step(for: "Digest: sha256:deadbeef"), .pullImage)
  }

  func testStepForLineMapsDaemonMarkers() {
    XCTAssertEqual(LinuxSetupProgress.step(for: "Starting colima..."), .verifyDaemon)
    XCTAssertEqual(LinuxSetupProgress.step(for: "colima is running"), .verifyDaemon)
    XCTAssertEqual(LinuxSetupProgress.step(for: "container system start"), .verifyDaemon)
  }

  func testStepForLineReturnsNilOnNoise() {
    XCTAssertNil(LinuxSetupProgress.step(for: "some unrelated log line"))
    XCTAssertNil(LinuxSetupProgress.step(for: ""))
  }

  func testDetailForLine() {
    XCTAssertEqual(LinuxSetupProgress.detail(for: "latest: Pulling from x"), "Fetching image layers…")
    XCTAssertEqual(LinuxSetupProgress.detail(for: "Extracting [==> ]"), "Extracting image layers…")
    XCTAssertEqual(LinuxSetupProgress.detail(for: "Status: Downloaded newer image"), "Image ready.")
    XCTAssertEqual(LinuxSetupProgress.detail(for: "Starting colima (vz)…"), "Starting the container VM (Colima)…")
    XCTAssertNil(LinuxSetupProgress.detail(for: "noise"))
  }

  func testTransientFailureClassifier() {
    // Network / registry blips → transient ("not your setup, retry").
    XCTAssertTrue(LinuxSetupProgress.isLikelyTransientFailure("Error: net/http: TLS handshake timeout"))
    XCTAssertTrue(LinuxSetupProgress.isLikelyTransientFailure("toomanyrequests: rate limit exceeded"))
    XCTAssertTrue(LinuxSetupProgress.isLikelyTransientFailure("could not resolve host: ghcr.io"))
    XCTAssertTrue(LinuxSetupProgress.isLikelyTransientFailure("received unexpected HTTP 503 Service Unavailable"))
    // A genuine local failure is NOT mislabeled as transient.
    XCTAssertFalse(LinuxSetupProgress.isLikelyTransientFailure("Cannot connect to the Docker daemon. Is the docker daemon running?"))
    XCTAssertFalse(LinuxSetupProgress.isLikelyTransientFailure("docker: command not found"))
  }
}
