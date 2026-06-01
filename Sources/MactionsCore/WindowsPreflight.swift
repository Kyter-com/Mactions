import Foundation

/// Prerequisite detection + a FREE/OSS-FIRST installer for the opt-in Windows
/// runner path, so the user never has to hand-run `brew`. Mirrors the rest of
/// the core's split: detection is structured + testable, and the actual
/// `brew install` is a **pure command builder** (`installCommands`) so tests pin
/// the command shapes without shelling out — the real run is a separate call
/// (`runInstall`).
///
/// FREE-FIRST policy (important): the recommended hypervisor is the **QEMU +
/// swtpm + edk2** stack (free, open-source, and fully headless — no Aqua login
/// session required), which is what we install when none is present. UTM remains
/// a supported runtime backend (free but Aqua-bound) when already installed.
/// Parallels is paid, so we NEVER recommend installing it and only prefer it when
/// it's *already present*. Homebrew is the install vehicle but is never
/// auto-installed — if it's absent we tell the user to install it from brew.sh.
public enum WindowsPreflight {

  // MARK: - Detected backends

  /// A hypervisor capable of booting a Windows 11 ARM guest. Ordered by the
  /// free-first preference the recommender uses.
  public enum Hypervisor: String, Equatable, Sendable {
    /// UTM — free + open-source, a supported runtime backend when present.
    /// Caveat: `utmctl` uses Apple's ScriptingBridge and needs an active GUI/login
    /// session (fine for this interactive app; fragile for an unattended launchd
    /// host — see docs), which is why QEMU is the recommended default instead.
    case utm
    /// Parallels — paid. Preferred ONLY if already installed; never recommended
    /// for install.
    case parallels
    /// QEMU — fully free, fully headless (no Aqua login session). The recommended
    /// default, wired into a provider via `QEMUCLI` + the `mactions-qemu-vm` helper.
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
    /// swtpm (the QEMU-paired software TPM 2.0 emulator). Required for the QEMU
    /// path because Win11 hard-requires TPM 2.0; UTM/Parallels bring their own.
    public let swtpm: Tool
    /// edk2 AArch64 UEFI firmware (the read-only CODE file and the per-VM-copied
    /// VARS template). Bundled with the `qemu` Homebrew formula under
    /// `/opt/homebrew/share/qemu/`; absent means the QEMU path can't boot Win.
    public let efiCode: Tool
    public let efiVars: Tool

    public init(
      homebrew: Tool, hypervisors: [Hypervisor: Tool], converters: [Tool],
      swtpm: Tool, efiCode: Tool, efiVars: Tool
    ) {
      self.homebrew = homebrew
      self.hypervisors = hypervisors
      self.converters = converters
      self.swtpm = swtpm
      self.efiCode = efiCode
      self.efiVars = efiVars
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

    /// `true` iff every piece of the QEMU stack is present (the qemu binary,
    /// swtpm, AND both EFI firmware files). This is what the free-first picker
    /// keys on — qemu alone is necessary but not sufficient.
    public var qemuStackReady: Bool {
      hypervisors[.qemu]?.installed == true
        && swtpm.installed && efiCode.installed && efiVars.installed
    }

    /// The FREE backend to recommend installing when none is present: QEMU
    /// (fully headless, no Aqua session required). UTM remains as an alternate
    /// the user can pick, but we never push them to install it.
    public static let recommendedFreeBackendToInstall: Hypervisor = .qemu

    /// The backend the provider should default to, free-first:
    ///   1. QEMU if its full stack is ready (fully headless, no Aqua session),
    ///   2. else UTM if installed (free, but needs a GUI login session),
    ///   3. else Parallels if installed (paid — only if already present),
    ///   4. else `nil` (none ready → the installer offers to add the QEMU stack).
    public var recommendedBackend: Hypervisor? {
      if qemuStackReady { return .qemu }
      if hypervisors[.utm]?.installed == true { return .utm }
      if hypervisors[.parallels]?.installed == true { return .parallels }
      if hypervisors[.qemu]?.installed == true { return .qemu }  // partial stack
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
  /// edk2 AArch64 UEFI firmware files ship inside Homebrew's `qemu` formula at
  /// `/opt/homebrew/share/qemu/`. The CODE file is read-only (the firmware
  /// image), the VARS file is the per-VM-copied template (boot order, Secure
  /// Boot keys persist in the copy).
  static let efiCodePath = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
  static let efiVarsPath = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"

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

    // QEMU-stack extras (only meaningful when the QEMU backend will be used).
    // swtpm is the software TPM 2.0 daemon. The two EFI .fd files are bundled
    // by Homebrew's qemu formula at fixed absolute paths. We reuse the same
    // `isExecutable` probe for the .fd paths (semantically: "path is present
    // on disk") so tests can mock both via the same `pathHits` set.
    let swtpm = Tool(name: "swtpm", path: whichLookup("swtpm"))
    let efiCode = Tool(
      name: "edk2-aarch64-code.fd", path: isExecutable(efiCodePath) ? efiCodePath : nil)
    let efiVars = Tool(
      name: "edk2-arm-vars.fd", path: isExecutable(efiVarsPath) ? efiVarsPath : nil)

    return Report(
      homebrew: homebrew, hypervisors: hypervisors, converters: converters,
      swtpm: swtpm, efiCode: efiCode, efiVars: efiVars)
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
  ///   - Hypervisor: only when NO hypervisor is fully present, install the
  ///     QEMU stack (`qemu` + `swtpm` — fully headless, no Aqua session). If a
  ///     hypervisor (incl. Parallels) is already there, install nothing extra.
  ///     We NEVER install Parallels (paid). We no longer push UTM — the QEMU
  ///     stack is the free default; UTM stays a runtime option but isn't pushed.
  ///   - If the QEMU binary exists but swtpm doesn't (or vice versa), install
  ///     the missing piece so the stack becomes whole.
  ///   - Install the missing converter formulae in one `brew install …`.
  ///   - If nothing is missing → `.nothingToInstall`.
  public static func installPlan(for report: Report) -> InstallPlan {
    guard let brew = report.homebrew.path else {
      return .homebrewMissing(message: homebrewInstallHint)
    }

    var commands: [BrewCommand] = []

    // QEMU stack: when no hypervisor is present we install qemu + swtpm. When
    // qemu IS present but the stack is incomplete (e.g. swtpm got uninstalled
    // independently), top it up so the chosen backend can actually boot.
    var hypervisorFormulae: [String] = []
    let qemuInstalled = report.hypervisors[.qemu]?.installed == true
    if !report.hasHypervisor {
      hypervisorFormulae += ["qemu", "swtpm"]
    } else if qemuInstalled && !report.qemuStackReady {
      if !report.swtpm.installed { hypervisorFormulae.append("swtpm") }
      // EFI firmware is bundled with the qemu formula; if it's absent it means
      // qemu wasn't installed via Homebrew (some non-brew install). Reinstall.
      if !report.efiCode.installed || !report.efiVars.installed {
        hypervisorFormulae.append("qemu")
      }
    }
    if !hypervisorFormulae.isEmpty {
      commands.append(BrewCommand(executable: brew, arguments: ["install"] + hypervisorFormulae))
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
  /// Iteration order for the installed-list. Note the free-first *recommendation*
  /// (what we install / `recommendedBackend`) is QEMU; this ordering only governs
  /// how `installedHypervisors` is listed.
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
