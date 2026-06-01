import Foundation

/// Prerequisite detection + a FREE/OSS installer for the opt-in Windows runner
/// path, so the user never has to hand-run `brew`. Mirrors the rest of the
/// core's split: detection is structured + testable, and the actual
/// `brew install` is a **pure command builder** (`installPlan`) so tests pin the
/// command shapes without shelling out — the real run is a separate call
/// (`runInstall`).
///
/// VMware Fusion (free since Nov 2024) is the PROVEN Win11-ARM backend and the
/// only one Mactions targets. It is NOT brew-installable (a Broadcom-portal
/// download), so the preflight DETECTS it and points the user to install it
/// manually — it never tries to `brew install` a hypervisor. What it DOES
/// auto-install (free, brew-able) are the UUP-dump ISO converter tools + xorriso
/// (used to remaster a no-prompt boot ISO). Homebrew is the install vehicle but
/// is never auto-installed — if it's absent we tell the user to get it from
/// brew.sh.
public enum WindowsPreflight {

  // MARK: - Detected backend

  /// The Windows-capable hypervisor. VMware Fusion is the sole backend (the
  /// proven Win11-ARM path on Apple Silicon); modeled as an enum so the UI can
  /// show a stable label.
  public enum Hypervisor: String, Equatable, Sendable {
    /// VMware Fusion — free, and the PROVEN Win11-ARM backend. Wired into a
    /// provider via `VMwareCLI` + the `mactions-fusion-vm` helper. NOT
    /// brew-installable (Broadcom-portal download), so detect-only.
    case vmwareFusion

    /// All supported backends are free.
    public var isFree: Bool { true }

    /// Human label for the checklist / status line.
    public var displayName: String {
      switch self {
      case .vmwareFusion: return "VMware Fusion (free)"
      }
    }
  }

  /// One detectable tool, with where it was found (`nil` == missing).
  public struct Tool: Equatable, Sendable {
    public let name: String
    /// Absolute path to the binary, or `nil` if not installed.
    public let path: String?
    public var installed: Bool { path != nil }
    public init(name: String, path: String?) {
      self.name = name
      self.path = path
    }
  }

  // MARK: - Detection report

  /// The structured result of a preflight scan: what's installed, what's
  /// missing. Pure data so the UI can render a checklist and tests can assert
  /// against it.
  public struct Report: Equatable, Sendable {
    /// Homebrew (`brew`) — the install vehicle for the free deps.
    public let homebrew: Tool
    /// VMware Fusion's `vmrun` (the "Fusion installed" signal). Manual install.
    public let fusion: Tool
    /// The UUP-dump → ISO converter tools (aria2c, cabextract, wimlib-imagex,
    /// mkisofs, chntpw) — the convert script hard-requires all of them.
    public let converters: [Tool]
    /// xorriso — remasters the Win11 install ISO into a NO-PROMPT boot ISO (so
    /// the headless base build needs no "Press any key" keypress). Optional: the
    /// build falls back to the prompting ISO without it, but we offer to install
    /// it so the base build is fully hands-free.
    public let xorriso: Tool

    public init(homebrew: Tool, fusion: Tool, converters: [Tool], xorriso: Tool) {
      self.homebrew = homebrew
      self.fusion = fusion
      self.converters = converters
      self.xorriso = xorriso
    }

    /// Is Homebrew installed? (Free-dep auto-install needs it.)
    public var homebrewInstalled: Bool { homebrew.installed }

    /// Is VMware Fusion installed?
    public var fusionInstalled: Bool { fusion.installed }

    /// `true` once a Windows-capable hypervisor is present (Fusion).
    public var hasHypervisor: Bool { fusionInstalled }

    /// The backend the provider will use, or `nil` if Fusion isn't installed.
    /// (Advisory / for the checklist UI — the live selection is
    /// `WindowsVMProviderFactory.detectInstalledCLI()`.)
    public var recommendedBackend: Hypervisor? { fusionInstalled ? .vmwareFusion : nil }

    /// xorriso present (for the no-prompt boot ISO)?
    public var xorrisoInstalled: Bool { xorriso.installed }

    /// Converter tools that are NOT installed (brew formula names — wimlib-imagex
    /// maps to the `wimlib` formula). Empty == all present.
    public var missingConverterFormulae: [String] {
      converters.filter { !$0.installed }.map { WindowsImage.brewFormula(for: $0.name) }
    }

    /// The free, brew-installable formulae that are missing: the converter tools
    /// plus xorriso. (Fusion is excluded — it's a manual Broadcom-portal
    /// download, never brew-installed.)
    public var missingFreeFormulae: [String] {
      var f = missingConverterFormulae
      if !xorriso.installed { f.append("xorriso") }
      return f
    }

    /// `true` when everything the no-ISO auto-download Windows path needs is in
    /// place: Homebrew (for installs), VMware Fusion, and all converter tools.
    /// (xorriso isn't required — the build falls back to a prompting ISO.)
    public var ready: Bool {
      homebrewInstalled && fusionInstalled && missingConverterFormulae.isEmpty
    }
  }

  // MARK: - Detection (impure: probes the filesystem)

  /// Common absolute locations a Finder-launched GUI app won't have on its
  /// inherited PATH, so we probe them directly (mirrors `Shell.which`).
  static let brewCandidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
  /// VMware Fusion's `vmrun` — inside the .app bundle (not on PATH). Its presence
  /// is the "Fusion installed" signal; Fusion is a manual Broadcom-portal download.
  static let vmrunPath = "/Applications/VMware Fusion.app/Contents/Library/vmrun"

  /// Scan the host for all Windows-runner prerequisites. The probe closures are
  /// injectable so the pure assembly (`makeReport`) can be unit-tested without
  /// touching the real filesystem.
  public static func detect() -> Report {
    makeReport(
      whichLookup: { Shell.which($0) },
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
    )
  }

  /// Pure report assembly given two probes:
  ///   - `whichLookup`: resolve a binary on PATH + Homebrew dirs (or `nil`).
  ///   - `isExecutable`: is there an executable at this absolute path?
  /// Split out so detection logic is unit-testable without a real brew/Fusion.
  static func makeReport(
    whichLookup: (String) -> String?,
    isExecutable: (String) -> Bool
  ) -> Report {
    // Homebrew: PATH first, then the two well-known install prefixes.
    let brewPath =
      whichLookup("brew") ?? brewCandidatePaths.first(where: isExecutable)
    let homebrew = Tool(name: "brew", path: brewPath)

    // VMware Fusion ships vmrun inside the .app bundle (not on PATH).
    let fusion = Tool(name: "vmrun", path: isExecutable(vmrunPath) ? vmrunPath : nil)

    // Converter tools for the no-ISO auto-download path. Probe by binary name;
    // the brew formula that provides each (e.g. aria2c→aria2, mkisofs→cdrtools,
    // chntpw→tap) is resolved by WindowsImage.brewFormula.
    let converters = WindowsImage.converterDependencies.map {
      Tool(name: $0.binary, path: whichLookup($0.binary))
    }

    // xorriso (for the no-prompt boot ISO remaster).
    let xorriso = Tool(name: "xorriso", path: whichLookup("xorriso"))

    return Report(homebrew: homebrew, fusion: fusion, converters: converters, xorriso: xorriso)
  }

  // MARK: - Free-deps install plan (pure → unit-testable)

  /// A single `brew` invocation the free-deps installer should run.
  public struct BrewCommand: Equatable, Sendable {
    /// Absolute path to the `brew` binary.
    public let executable: String
    /// Args (e.g. `["install", "aria2", "xorriso"]`).
    public let arguments: [String]
    public init(executable: String, arguments: [String]) {
      self.executable = executable
      self.arguments = arguments
    }
  }

  /// The outcome of planning the free-deps install: either a list of `brew`
  /// commands to run, "nothing to do", or "you must install Homebrew first".
  public enum InstallPlan: Equatable, Sendable {
    /// Homebrew is missing — we do NOT auto-install it. Carries the brew.sh hint.
    case homebrewMissing(message: String)
    /// All free prerequisites are already present.
    case nothingToInstall
    /// The exact `brew` commands to run for the MISSING free deps only.
    case install([BrewCommand])
  }

  /// Where we point the user when `brew` is absent (we never auto-install it).
  public static let homebrewInstallHint =
    "Install Homebrew first: https://brew.sh (then re-run \"Install free prerequisites\")."

  /// Build the FREE-deps install plan from a detection report — a PURE function
  /// so it's unit-testable without shelling out. The real run is `runInstall`.
  ///
  /// Policy baked in here:
  ///   - If `brew` is missing → `.homebrewMissing` (never auto-install Homebrew).
  ///   - Install the missing FREE brew formulae in one `brew install …`: the
  ///     UUP-dump converter tools + xorriso (for the no-prompt boot ISO).
  ///   - We NEVER install a hypervisor — VMware Fusion is a manual Broadcom-portal
  ///     download. The checklist tells the user to install it; this plan doesn't.
  ///   - If nothing is missing → `.nothingToInstall`.
  public static func installPlan(for report: Report) -> InstallPlan {
    guard let brew = report.homebrew.path else {
      return .homebrewMissing(message: homebrewInstallHint)
    }
    let missing = report.missingFreeFormulae
    guard !missing.isEmpty else { return .nothingToInstall }
    return .install([BrewCommand(executable: brew, arguments: ["install"] + missing)])
  }

  // MARK: - Free-deps install (impure: shells out — separate from planning)

  /// The outcome of actually running the free-deps install.
  public enum InstallResult: Equatable, Sendable {
    /// `brew` was absent — nothing ran (carries the brew.sh hint).
    case homebrewMissing(message: String)
    /// Nothing needed installing.
    case nothingToInstall
    /// All planned `brew` commands succeeded.
    case installed
    /// A `brew` command failed; carries which command + the captured stderr.
    case failed(command: String, stderr: String)
  }

  /// Run the free-deps install plan for the given report. Shells out via
  /// `Shell.run`, so callers should invoke it OFF the main actor. NEVER installs
  /// a hypervisor (Fusion is manual) and never installs Homebrew. Stops at the
  /// first failing command.
  ///
  /// `runner` is injectable purely so the loop's accounting can be tested without
  /// a real `brew`; it returns the command's exit status + captured stderr (a
  /// `nil` status means the command couldn't be launched). Production passes the
  /// default (the live `Shell.run`).
  @discardableResult
  public static func runInstall(
    for report: Report,
    runner: (BrewCommand) -> (status: Int32?, stderr: String) = { cmd in
      guard let result = try? Shell.run(cmd.executable, cmd.arguments) else {
        return (nil, "could not launch \(cmd.executable)")
      }
      return (result.status, result.stderr)
    }
  ) -> InstallResult {
    switch installPlan(for: report) {
    case let .homebrewMissing(message):
      return .homebrewMissing(message: message)
    case .nothingToInstall:
      return .nothingToInstall
    case let .install(commands):
      for command in commands {
        let outcome = runner(command)
        guard outcome.status == 0 else {
          return .failed(
            command: ([command.executable] + command.arguments).joined(separator: " "),
            stderr: outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
      return .installed
    }
  }
}
