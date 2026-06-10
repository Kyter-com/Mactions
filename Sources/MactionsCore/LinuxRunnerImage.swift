import Foundation

/// The Linux runner **container image** acquisition story — the analog of
/// `RunnerInstaller` for macOS, but a container image pull (seconds) instead of a
/// tarball download or a 30–40 min Windows base build.
///
/// We use the **official** `ghcr.io/actions/actions-runner` image: a multi-arch
/// OCI manifest with a native `linux/arm64` variant (no emulation on Apple
/// Silicon), built `FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble` with
/// the agent's native deps (libicu/libssl/libkrb5/zlib) pre-baked — so no
/// in-guest `installdependencies.sh` is needed. Pulling and refreshing it (with
/// a `.image-version` sentinel) is the direct analog of `RunnerInstaller`
/// refreshing the cached agent template, and it keeps clones from re-paying the
/// agent self-update.
///
/// The pure pieces (image ref, sentinel path, pull-needed decision) live here so
/// they're unit-testable; the actual `pull` is shelled out by the app via the
/// `LinuxContainerCLI.pullArgs` builder.
public enum LinuxRunnerImage {
  /// The official runner image repository. Public, so anonymous pulls work.
  public static let repository = "ghcr.io/actions/actions-runner"

  /// A fully-qualified image reference. `version == nil` → `:latest` (always
  /// published; auto-refreshes). A pinned version is `:<version>` for
  /// reproducibility — but note the **container** tag stream is independent of
  /// the `actions/runner` *agent* release stream, so a freshly-cut agent version
  /// may not yet have a matching image tag; prefer `:latest` unless a specific
  /// tag is known to exist.
  public static func imageRef(version: String? = nil) -> String {
    guard let version, !version.isEmpty else { return "\(repository):latest" }
    let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
    return "\(repository):\(v)"
  }

  /// Where we record the image ref last pulled, so a refresh only re-pulls on a
  /// change (mirrors `RunnerInstaller` writing `.version`). Under `~/.mactions`.
  public static func versionSentinel() -> URL {
    HostCleanup.mactionsRoot().appendingPathComponent(".linux-image-version", isDirectory: false)
  }

  /// The image ref recorded by the last successful pull, or `nil` if none.
  public static func recordedImageRef() -> String? {
    guard let raw = try? String(contentsOf: versionSentinel(), encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Persist the image ref just pulled. Best-effort.
  public static func recordImageRef(_ ref: String) {
    try? FileManager.default.createDirectory(
      at: HostCleanup.mactionsRoot(), withIntermediateDirectories: true)
    try? ref.write(to: versionSentinel(), atomically: true, encoding: .utf8)
  }

  /// Whether a pull is needed: no record yet, or the desired ref differs from the
  /// recorded one. A `:latest` desired ref is treated as always-stale only when
  /// nothing has been pulled — once pulled, refreshing `:latest` is the app's
  /// choice (it can force a re-pull on a cadence), not something this decides.
  public static func pullNeeded(desired: String, recorded: String? = recordedImageRef()) -> Bool {
    guard let recorded else { return true }
    return desired != recorded
  }
}
