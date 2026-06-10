import Foundation

/// How many concurrent Win11-ARM VMs the host can run without thrashing.
///
/// Each per-job runner is a full VM (default 8 GB RAM / 4 vCPU), so N combos
/// each booting one simultaneously would otherwise exhaust physical RAM and lag
/// the whole Mac. This is the pure, unit-testable formula go-online uses to
/// seed the shared `HostBudget` ledger's Windows ceiling — capacity is spent
/// live at provision time and refunded on exit, not granted per fleet up front.
///
/// SCOPE (important): this bounds the **Windows VMs** in isolation — `reservedGB`
/// is a flat allowance for macOS + the app + IDLE macOS runner agents, NOT a
/// per-active-macOS-job reserve. A macOS runner mid-job can consume several GB,
/// so on a small Mac with many repos / high per-combo max counts the macOS fleet
/// plus the budgeted Windows VMs can still exceed physical RAM. The budget keeps
/// Windows VMs from thrashing the host on their own; it does not model total
/// fleet RAM. (`8 GB` per VM is the default the base-build scripts also use; the
/// app passes the base VMX's actual `memsize` via `perVMGB` so a non-default
/// `--ram` base stays in sync — see `perVMGB(fromVMX:)`.)
public enum WindowsVMBudget {
  /// The default per-VM RAM footprint in GB. Single source of truth on the Swift
  /// side; mirrors `RAM_MB=8192` in `scripts/prepare-windows-image` /
  /// `fusion-windows-base`. The app prefers the base VMX's real `memsize` and
  /// falls back to this when it can't be read.
  public static let defaultPerVMGB = 8

  /// Max concurrent Windows VMs given the host's physical memory.
  ///
  /// Reserves `reservedGB` for macOS, the app, and the lightweight macOS runner
  /// agents, then divides the remainder by the per-VM footprint. Returns `0`
  /// when the host can't fit even one VM without thrashing — the caller should
  /// then skip the Windows fleet entirely and tell the user, rather than swap
  /// the machine to its knees.
  public static func maxConcurrentVMs(
    physicalMemoryBytes: UInt64,
    perVMGB: Int = defaultPerVMGB,
    reservedGB: Int = 6
  ) -> Int {
    let totalGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
    let usableGB = totalGB - reservedGB
    guard perVMGB > 0, usableGB >= perVMGB else { return 0 }
    return usableGB / perVMGB
  }

  /// Parse the per-VM RAM footprint (GB, rounded UP) from a base `.vmx`'s
  /// `memsize = "MB"` line. Linked clones inherit the base `memsize`, so this is
  /// the clone's real footprint — the budget must divide by THIS, not a
  /// hardcoded default, or a `--ram 16384` base double-books RAM (and `--ram
  /// 4096` under-provisions). Pure so it's unit-testable; returns `nil` when no
  /// parseable `memsize` is present (the caller then falls back to
  /// `defaultPerVMGB`). Rounds up so we never UNDER-reserve.
  public static func perVMGB(fromVMX contents: String) -> Int? {
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let parts = rawLine.split(separator: "=", maxSplits: 1)
      guard parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "memsize"
      else { continue }
      let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
      guard let mb = Int(value), mb > 0 else { return nil }
      return (mb + 1023) / 1024  // MB -> GB, round up
    }
    return nil
  }
}
