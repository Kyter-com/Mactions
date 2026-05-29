import Foundation

/// Prerequisite detection + a FREE/OSS-FIRST installer for the opt-in Windows
/// runner path, so the user never has to hand-run `brew`. Mirrors the rest of
/// the core's split: detection is structured + testable, and the actual
/// `brew install` is a **pure command builder** (`installCommands`) so tests pin
/// the command shapes without shelling out — the real run is a separate call
/// (`runInstall`).
///
/// FREE-FIRST policy (important): the recommended hypervisor is **UTM** (free,
/// open-source). Parallels is paid, so we NEVER recommend installing it and only
/// prefer it when it's *already present*. QEMU is noted as a deeper free fallback
/// (not wired into a provider here). Homebrew is the install vehicle but is never
/// auto-installed — if it's absent we tell the user to install it from brew.sh.
public enum WindowsPreflight {

  // MARK: - Detected backends

  /// A hypervisor capable of booting a Windows 11 ARM guest. Ordered by the
  /// free-first preference the recommender uses.
  public enum Hypervisor: String, Equatable, Sendable {
    /// UTM — free + open-source. The recommended default. Caveat: `utmctl` uses
    /// Apple's ScriptingBridge and needs an active GUI/login session (fine for
    /// this interactive app; fragile for an unattended launchd host — see docs).
    case utm
    /// Parallels — paid. Preferred ONLY if already installed; never recommended
    /// for install.
    case parallels
    /// QEMU — fully free, no GUI-session dependency, but more DIY plumbing. A
    /// deeper free fallback; not wired into a provider here.
    case qemu

    /// `true` for the free/OSS backends (UTM, QEMU) — the ones we may recommend
    /// or auto-install. Parallels (paid) is excluded.
    public var isFree: Bool { self != .parallels }
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
  /// missing, and the free-first recommended backend. Pure data so the UI can
  /// render a checklist and tests can assert against it.
  public struct Report: Equatable, Sendable {
    /// Homebrew (`brew`) — the install vehicle for the free deps.
    public let homebrew: Tool
    /// Every hypervisor backend we probed (UTM, Parallels, QEMU), installed-or-not.
    public let hypervisors: [Hypervisor: Tool]
    /// The UUP-dump → ISO converter tools (aria2c, cabextract, wimlib-imagex,
    /// mkisofs, chntpw) — the convert script hard-requires all of them.
    public let converters: [Tool]

    public init(homebrew: Tool, hypervisors: [Hypervisor: Tool], converters: [Tool]) {
      self.homebrew = homebrew
      self.hypervisors = hypervisors
      self.converters = converters
    }

    /// Is Homebrew installed? (Free-dep auto-install needs it.)
    public var homebrewInstalled: Bool { homebrew.installed }

    /// The hypervisors that are actually installed.
    public var installedHypervisors: [Hypervisor] {
      Hypervisor.allOrdered.filter { hypervisors[$0]?.installed == true }
    }

    /// `true` once at least one Windows-capable hypervisor is present.
    public var hasHypervisor: Bool { !installedHypervisors.isEmpty }

    /// Converter tools that are NOT installed (brew formula names — wimlib-imagex
    /// maps to the `wimlib` formula). Empty == all present.
    public var missingConverterFormulae: [String] {
      converters.filter { !$0.installed }.map { WindowsImage.brewFormula(for: $0.name) }
    }

    /// The FREE backend to recommend installing when none is present: UTM. We
    /// never recommend Parallels (paid). If a free one is already installed we
    /// don't need to install anything.
    public static let recommendedFreeBackendToInstall: Hypervisor = .utm

    /// The backend the provider should default to, free-first:
    ///   1. UTM if installed (free, the default),
    ///   2. else Parallels if installed (paid — only if the user already has it),
    ///   3. else QEMU if installed,
    ///   4. else `nil` (none present → the installer offers to add UTM).
    public var recommendedBackend: Hypervisor? {
      if hypervisors[.utm]?.installed == true { return .utm }
      if hypervisors[.parallels]?.installed == true { return .parallels }
      if hypervisors[.qemu]?.installed == true { return .qemu }
      return nil
    }

    /// `true` when everything the no-ISO auto-download Windows path needs is in
    /// place: Homebrew (for installs), a hypervisor, and all converter tools.
    public var ready: Bool {
      homebrewInstalled && hasHypervisor && missingConverterFormulae.isEmpty
    }
  }

  // MARK: - Detection (impure: probes the filesystem)

  /// Common absolute locations a Finder-launched GUI app won't have on its
  /// inherited PATH, so we probe them directly (mirrors `Shell.which`).
  static let brewCandidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
  static let utmctlPath = "/Applications/UTM.app/Contents/MacOS/utmctl"

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
  /// Split out so detection logic (which tool, which path, free-first ordering)
  /// is unit-testable without a real `brew`/UTM install.
  static func makeReport(
    whichLookup: (String) -> String?,
    isExecutable: (String) -> Bool
  ) -> Report {
    // Homebrew: PATH first, then the two well-known install prefixes.
    let brewPath =
      whichLookup("brew") ?? brewCandidatePaths.first(where: isExecutable)
    let homebrew = Tool(name: "brew", path: brewPath)

    // Hypervisors, free-first:
    //   UTM ships utmctl inside the .app bundle (not on PATH);
    //   Parallels' prlctl + QEMU's qemu-system-aarch64 are PATH/Homebrew bins.
    let utm = Tool(
      name: "utmctl",
      path: isExecutable(utmctlPath) ? utmctlPath : nil)
    let parallels = Tool(name: "prlctl", path: whichLookup("prlctl"))
    let qemu = Tool(name: "qemu-system-aarch64", path: whichLookup("qemu-system-aarch64"))
    let hypervisors: [Hypervisor: Tool] = [
      .utm: utm, .parallels: parallels, .qemu: qemu,
    ]

    // Converter tools for the no-ISO auto-download path. Probe by binary name;
    // the brew formula that provides each (e.g. aria2c→aria2, mkisofs→cdrtools,
    // chntpw→tap) is carried on the dependency and resolved by WindowsImage.brewFormula.
    let converters = WindowsImage.converterDependencies.map {
      Tool(name: $0.binary, path: whichLookup($0.binary))
    }

    return Report(homebrew: homebrew, hypervisors: hypervisors, converters: converters)
  }

  // MARK: - Free-deps install plan (pure → unit-testable)

  /// A single `brew` invocation the free-deps installer should run.
  public struct BrewCommand: Equatable, Sendable {
    /// Absolute path to the `brew` binary.
    public let executable: String
    /// Args (e.g. `["install", "--cask", "utm"]`).
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
  ///   - Install UTM (`brew install --cask utm`) ONLY if no hypervisor is present
  ///     yet. UTM is free/OSS; we NEVER install Parallels (paid). If the user
  ///     already has *any* hypervisor (incl. Parallels), we add no hypervisor.
  ///   - Install the missing converter formulae in one `brew install …`.
  ///   - If nothing is missing → `.nothingToInstall`.
  public static func installPlan(for report: Report) -> InstallPlan {
    guard let brew = report.homebrew.path else {
      return .homebrewMissing(message: homebrewInstallHint)
    }

    var commands: [BrewCommand] = []

    // Hypervisor: add the free default (UTM) only when none is installed. Never
    // Parallels — it's paid, and if it's already present `hasHypervisor` is true.
    if !report.hasHypervisor {
      commands.append(
        BrewCommand(executable: brew, arguments: ["install", "--cask", "utm"]))
    }

    // Converter tools: one `brew install` for all the missing formulae.
    let missing = report.missingConverterFormulae
    if !missing.isEmpty {
      commands.append(BrewCommand(executable: brew, arguments: ["install"] + missing))
    }

    return commands.isEmpty ? .nothingToInstall : .install(commands)
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
  /// `Shell.run`, so callers should invoke it OFF the main actor. NEVER touches
  /// Parallels and never installs Homebrew. Stops at the first failing command.
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

extension WindowsPreflight.Hypervisor {
  /// Free-first iteration order: UTM (free default), Parallels (paid, only if
  /// present), QEMU (deeper free fallback).
  static let allOrdered: [WindowsPreflight.Hypervisor] = [.utm, .parallels, .qemu]

  /// Human label for the checklist / status line.
  public var displayName: String {
    switch self {
    case .utm: return "UTM (free)"
    case .parallels: return "Parallels (paid)"
    case .qemu: return "QEMU (free)"
    }
  }
}
