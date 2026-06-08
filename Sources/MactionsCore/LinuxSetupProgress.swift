import Foundation

/// The ordered, user-facing phases of Linux runner setup, and a PURE parser that
/// maps a line of `docker`/`container` `pull` output to the phase it signals.
/// The Linux analog of `WindowsSetupProgress` — but where the Windows base build
/// is a 5-phase, 30–40 min headless install, Linux setup is just **verify the
/// container daemon** then **pull the runner image** (seconds), so it collapses
/// to two fast steps.
///
/// The app streams the CLI's stdout/stderr (`Shell.runStreaming`) and feeds each
/// line here to drive a live stepper, exactly like the Windows path. Steps only
/// ever advance FORWARD in the UI (see `Comparable`), so a stray marker can't
/// regress the indicator.
public enum LinuxSetupStep: Int, CaseIterable, Sendable, Comparable {
  /// Confirm a container runtime is installed and its daemon is up
  /// (`colima start` / `container system start` if needed). App-driven.
  case verifyDaemon = 0
  /// Pull the official runner image (`ghcr.io/actions/actions-runner`, arm64).
  case pullImage

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// Short label for the stepper row.
  public var title: String {
    switch self {
    case .verifyDaemon: return "Checking container runtime"
    case .pullImage: return "Pulling runner image"
    }
  }

  /// One-line hint shown under the active step.
  public var hint: String {
    switch self {
    case .verifyDaemon: return "Verifying the container daemon is installed and running."
    case .pullImage: return "Downloading ghcr.io/actions/actions-runner (arm64) — usually seconds."
    }
  }
}

public enum LinuxSetupProgress {
  /// The step a line of setup output signals the START of, or `nil` if the line
  /// isn't a recognizable marker. Checked most-advanced-first.
  public static func step(for line: String) -> LinuxSetupStep? {
    let l = line.lowercased()
    // pull / image (docker: "Pulling from", "Pull complete", "Downloading",
    // "Status: Downloaded"; container: "pulling image", "downloading")
    if l.contains("pulling") || l.contains("pull complete") || l.contains("downloading")
      || l.contains("downloaded") || l.contains("extracting") || l.contains("digest:")
    {
      return .pullImage
    }
    // daemon verify
    if l.contains("starting colima") || l.contains("colima is running")
      || l.contains("container runtime") || l.contains("daemon")
      || l.contains("system start") || l.contains("verifying")
    {
      return .verifyDaemon
    }
    return nil
  }

  /// A short, friendly sub-status for the active step, or `nil` to keep the
  /// previous detail.
  public static func detail(for line: String) -> String? {
    let l = line.lowercased()
    if l.contains("pulling from") { return "Fetching image layers…" }
    if l.contains("extracting") { return "Extracting image layers…" }
    if l.contains("pull complete") || l.contains("status: downloaded") || l.contains("digest:") {
      return "Image ready."
    }
    if l.contains("starting colima") { return "Starting the container VM (Colima)…" }
    if l.contains("system start") { return "Starting the container daemon…" }
    return nil
  }

  /// Heuristic: did a FAILED setup die from a TRANSIENT cause (registry/network
  /// blip) that's safe to retry and NOT the user's setup — vs a genuine local
  /// failure (no daemon, no CLI installed). Drives a "not your setup — retry"
  /// banner. Conservative so a real local failure isn't mislabeled.
  public static func isLikelyTransientFailure(_ output: String) -> Bool {
    let s = output.lowercased()
    let transient = [
      "timeout", "timed out", "temporary failure", "connection reset",
      "connection refused", "could not resolve host", "network is unreachable",
      "i/o timeout", "tls handshake", "500 internal", "502 bad gateway",
      "503 service", "registry", "toomanyrequests", "rate limit",
      "no route to host", "eof",
    ]
    return transient.contains { s.contains($0) }
  }
}
