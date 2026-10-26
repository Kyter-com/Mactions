import Foundation

/// The `LaunchGate`'s network check for Linux: one short-lived container from
/// the runner image, asking whether a VM can reach GitHub at all.
///
/// Why from inside a VM: the host can be online while its VMs are not. On
/// 2026-10-24, with a full-tunnel VPN up (the host's default route on
/// `utun420`), the host reached GitHub through the tunnel, but inside a Linux
/// VM `getent hosts github.com` failed against the VM's resolver
/// (192.168.64.1) and even a TCP connect to 1.1.1.1:443 failed. Every runner
/// registered with GitHub (the host did that) and then never connected. Only a
/// check that runs where the runner runs can see this, and it costs no JIT
/// registration or GitHub API call.
public enum LinuxNetworkProbe {
  /// What the check found inside the VM.
  public enum Finding: Equatable, Sendable {
    case reachable
    /// `github.com` does not resolve, but the VM can open a connection by IP.
    case dnsFailed
    /// Neither names nor a connection by IP work: the VM has no network.
    case noNetwork
    /// `github.com` resolves, but its port 443 cannot be reached.
    case connectFailed
    /// The container did not run the check; the CLI's own words.
    case couldNotRun(String)
    /// The container did not finish within the check's time limit.
    case timedOut(TimeInterval)
  }

  public static let marker = "mactions-probe:"

  /// Runs inside the runner image (Ubuntu, so bash, coreutils `timeout` and
  /// glibc `getent` are present). Every outcome exits 0 and prints exactly one
  /// marker line, so a missing marker means the script never ran. Each step is
  /// bounded at 10 s: a dead resolver otherwise retries for much longer.
  public static let script = """
    p=\(marker)
    if timeout 10 getent hosts github.com >/dev/null 2>&1; then
      if timeout 10 bash -c 'exec 3<>/dev/tcp/github.com/443' >/dev/null 2>&1; then
        echo "${p}ok"
      else
        echo "${p}connect"
      fi
    elif timeout 10 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1; then
      echo "${p}dns"
    else
      echo "${p}offline"
    fi
    """

  /// Worst case inside: two 10 s steps, after a container start that took up
  /// to ~6 s live. A minute leaves room for a cold start without letting a hung
  /// CLI hold the check forever.
  public static let defaultTimeout: TimeInterval = 60

  /// `mactions-` prefixed, so the go-online orphan sweep deletes a probe the
  /// app was killed in the middle of.
  public static func containerName() -> String {
    "mactions-probe-\(String(UUID().uuidString.prefix(8)).lowercased())"
  }

  /// Read the container's output. The marker decides; without one, the CLI's
  /// last stderr line (its error, after the progress lines) says why.
  public static func finding(status: Int32, stdout: String, stderr: String) -> Finding {
    let markerLine = stdout.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { $0.hasPrefix(marker) }
    switch markerLine.map({ String($0.dropFirst(marker.count)) }) {
    case "ok": return .reachable
    case "connect": return .connectFailed
    case "dns": return .dnsFailed
    case "offline": return .noNetwork
    default:
      let lastError = stderr.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty && !$0.hasPrefix("[") }  // skip "[6/6] Starting container" progress
      return .couldNotRun(lastError ?? "exit status \(status)")
    }
  }

  /// One sentence for the dashboard, plus a hint when the host's own traffic
  /// leaves through a tunnel interface (a VPN), the setup that broke VM
  /// networking on 2026-10-24.
  public static func result(for finding: Finding, tunnelInterface: String?) -> LaunchGate.ProbeResult
  {
    let detail: String
    switch finding {
    case .reachable:
      return LaunchGate.ProbeResult(reachable: true, detail: "Linux VMs can reach github.com.")
    case .dnsFailed:
      detail = "Linux VMs can't look up github.com (DNS fails inside the VM)."
    case .noNetwork:
      detail = "Linux VMs have no network: DNS and connections from inside the VM both fail."
    case .connectFailed:
      detail = "Linux VMs can't connect to github.com on port 443."
    case .couldNotRun(let why):
      detail = "Couldn't run the Linux network check: \(String(why.prefix(200)))"
    case .timedOut(let seconds):
      detail = "The Linux network check didn't finish within \(Int(seconds))s."
    }
    guard let tunnelInterface else { return LaunchGate.ProbeResult(reachable: false, detail: detail) }
    switch finding {
    case .dnsFailed, .noNetwork, .connectFailed, .timedOut:
      return LaunchGate.ProbeResult(
        reachable: false,
        detail: detail
          + " This Mac sends its traffic through a VPN (\(tunnelInterface)), which can cut VMs off;"
          + " disconnect it or allow local network traffic, and runners resume on their own.")
    case .reachable, .couldNotRun:
      return LaunchGate.ProbeResult(reachable: false, detail: detail)
    }
  }

  /// Run the check (blocking: call it off the main actor). Never throws; a
  /// check that cannot run is reported as such, and the container is removed
  /// whatever happened (`--rm` removes it asynchronously, and not at all when
  /// the CLI is killed).
  public static func run(
    cli: LinuxContainerCLI, image: String, timeout: TimeInterval = defaultTimeout,
    tunnelInterface: () -> String? = { HostRoute.tunnelInterface() }
  ) -> LaunchGate.ProbeResult {
    let name = containerName()
    let found: Finding
    do {
      let output = try Shell.run(
        cli.executable, cli.probeArgs(name: name, image: image, script: script), timeout: timeout)
      found = finding(status: output.status, stdout: output.stdout, stderr: output.stderr)
    } catch Shell.ShellError.timedOut(_, let seconds) {
      found = .timedOut(seconds)
    } catch {
      found = .couldNotRun(String(describing: error))
    }
    _ = try? Shell.run(cli.executable, cli.rmArgs(name: name), timeout: 20)
    let reachable = found == .reachable
    return result(for: found, tunnelInterface: reachable ? nil : tunnelInterface())
  }
}

/// Which interface the host's own internet traffic leaves through, to tell
/// the user when a VPN is the likely reason VMs are cut off.
public enum HostRoute {
  /// The interface `route -n get 1.1.1.1` reports, when it is a tunnel
  /// (`utun`, `ipsec`, `ppp`, `tun`, `tap`, `wg`): a full-tunnel VPN. `nil`
  /// when traffic leaves directly or the route can't be read.
  public static func tunnelInterface(timeout: TimeInterval = 5) -> String? {
    guard let output = try? Shell.run("/sbin/route", ["-n", "get", "1.1.1.1"], timeout: timeout),
      output.ok, let name = interface(fromRouteGet: output.stdout), isTunnel(name)
    else { return nil }
    return name
  }

  /// The `interface:` line of `route -n get` output.
  public static func interface(fromRouteGet output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface"
      else { continue }
      let name = parts[1].trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : name
    }
    return nil
  }

  public static func isTunnel(_ interface: String) -> Bool {
    let lowered = interface.lowercased()
    let prefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
    return prefixes.contains { prefix in
      lowered.hasPrefix(prefix) && lowered.dropFirst(prefix.count).allSatisfy(\.isNumber)
    }
  }
}
