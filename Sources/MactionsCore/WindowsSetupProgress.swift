import Foundation

/// The ordered, user-facing phases of the one-time Windows base-image build, and
/// a PURE parser that maps a line of `prepare-windows-image` / `fusion-windows-base`
/// output to the phase it signals. Pure + unit-testable like the rest of the core
/// — the app streams the scripts' stdout/stderr (`Shell.runStreaming`) and feeds
/// each line here to drive a live stepper in the popover instead of one opaque
/// spinner.
///
/// The scripts already emit `==>` phase markers (and `[Ns] still running` ticks
/// during the long headless install); this maps those substrings to steps. Steps
/// only ever advance FORWARD in the UI (a resumed run that skips the download
/// jumps straight to a later step), so a stray/duplicate marker can't regress the
/// indicator — see `Comparable`.
public enum WindowsSetupStep: Int, CaseIterable, Sendable, Comparable {
  /// Preflight + free-dep (`brew`) install. App-driven (before the script runs).
  case prerequisites = 0
  /// Resolve + download the ~8 GB Win11 ARM64 media (UUP dump) and convert to ISO
  /// — or reuse a cached ISO on a resumed run.
  case downloadISO
  /// Build the unattended-install ISO + the no-prompt boot ISO.
  case buildMedia
  /// Author + boot the VM headless; the unattended Win11 install + `bootstrap.ps1`
  /// run inside. The long step (~25–40 min).
  case installWindows
  /// Verify provisioning + snapshot the pristine base (`base-provisioned`).
  case finalize

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// Short label for the stepper row.
  public var title: String {
    switch self {
    case .prerequisites: return "Checking prerequisites"
    case .downloadISO: return "Downloading Windows 11 ARM64"
    case .buildMedia: return "Preparing install media"
    case .installWindows: return "Installing Windows (headless)"
    case .finalize: return "Snapshotting the base image"
    }
  }

  /// One-line hint shown under the active step (sets expectations on duration).
  public var hint: String {
    switch self {
    case .prerequisites: return "Verifying VMware Fusion + installing free tools via Homebrew."
    case .downloadISO: return "~8 GB from UUP dump, then convert to an ISO — the slow part. Resumes if interrupted."
    case .buildMedia: return "Authoring the unattended + no-prompt boot ISOs."
    case .installWindows: return "Unattended Windows install + agent bootstrap inside the VM. ~25–40 min."
    case .finalize: return "Verifying the provisioning sentinel, then taking the base snapshot."
    }
  }
}

public enum WindowsSetupProgress {
  /// The step a line of build output signals the START of, or `nil` if the line
  /// isn't a phase marker. Checked most-advanced-first so a line is attributed to
  /// its furthest phase; substrings are distinct so order is just belt-and-braces.
  public static func step(for line: String) -> WindowsSetupStep? {
    let l = line.lowercased()
    // finalize
    if l.contains("provisioning verified") || l.contains("snapshotting the provisioned base")
      || l.contains("base image ready") || l.contains("base build done")
    {
      return .finalize
    }
    // install (the VM build, incl. its progress ticks)
    if l.contains("headless base build") || l.contains("gb disk:") || l.contains("authoring")
      || l.contains("booting headless") || l.contains("watching install")
      || l.contains("backing up prior base") || l.contains("still running")
      || l.contains("provisioning sentinel present")
    {
      return .installWindows
    }
    // build media (ISOs) — incl. the resumed run reusing the cached no-prompt
    // boot ISO ("Reusing the cached no-prompt Win11 ISO …"), distinct from the
    // download-cache hit below.
    if l.contains("building unattended-install iso") || l.contains("stashing unattend iso")
      || l.contains("preparing the win11 boot iso") || l.contains("reusing the cached no-prompt")
    {
      return .buildMedia
    }
    // download / convert (or a resumed run reusing the cached ISO)
    if l.contains("resolving the latest") || l.contains("fetching the uup")
      || l.contains("reusing cached win11") || l.contains("built iso:")
    {
      return .downloadISO
    }
    return nil
  }

  /// A short, friendly sub-status for the active step (the `[Ns] still running`
  /// install ticks, key milestones, the resume notice), or `nil` to keep the
  /// previous detail. Surfaced under the current stepper row.
  public static func detail(for line: String) -> String? {
    let l = line.lowercased()
    if l.contains("still running") {
      // "    [  742s] still running (provisioned=0)..." → "Installing… (12m elapsed)"
      if let secs = firstBracketedSeconds(in: line) {
        return "Installing… (\(humanDuration(secs)) elapsed)"
      }
      return "Installing…"
    }
    if l.contains("provisioning sentinel present") { return "Provisioning verified — finishing up." }
    if l.contains("reusing cached win11") { return "Reusing the cached ISO from the last attempt (resumed)." }
    if l.contains("reusing the cached no-prompt") { return "Reusing the cached boot ISO (resumed)." }
    if l.contains("fetching the uup") { return "Downloading + converting the ISO (resumes through network drops)." }
    if l.contains("booting headless") { return "Booting the VM for the unattended install…" }
    if l.contains("snapshotting the provisioned base") { return "Taking the base snapshot…" }
    return nil
  }

  /// Pull the integer seconds out of a leading `[ 742s]` tick, if present.
  static func firstBracketedSeconds(in line: String) -> Int? {
    guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]")
    else { return nil }
    let inside = line[line.index(after: open)..<close]
      .replacingOccurrences(of: "s", with: "")
      .trimmingCharacters(in: .whitespaces)
    return Int(inside)
  }

  /// "742" → "12m", "45" → "45s", "3700" → "1h 1m". Compact, for the tick detail.
  static func humanDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h \(m % 60)m"
  }
}
