import Foundation

/// Host-wide circuit breaker for runner LAUNCHES, kept per OS and shared by
/// every orchestrator, like `HostBudget`.
///
/// Why it exists: a runner whose VM cannot reach GitHub is reaped as a
/// never-confirmed zombie after `neverConfirmedReapInterval`, and the next
/// reconcile tick launches a replacement into the same broken network. On
/// 2026-10-24, on plane Wi-Fi with a full-tunnel VPN, the VMs lost the network
/// while the host kept it: one Linux combo minted and booted a runner every
/// ~2.5 minutes (33 launches, 17 never-online reaps in 45 minutes), each a
/// fresh JIT registration and VM boot, and nothing told the user why. The
/// per-orchestrator `launchFailing` flag only changed a badge.
///
/// The gate pauses launches for an OS after `failureThreshold` consecutive
/// launch failures anywhere on the host (the network is host-wide, so a second
/// repo's fleet must not burn its own failures to learn the same thing):
///
/// - An OS with a network probe (Linux: a throwaway container that checks
///   GitHub) is probed right away on its first pause, and again on a growing
///   backoff; a passing probe resumes launching.
/// - An OS without one (Windows VMs are too heavy to boot as a check; macOS
///   runs on the host network) gets one TRIAL launch per backoff period; the
///   trial reaching GitHub resumes launching.
/// - Any runner of that OS confirming online resumes it, and resets the backoff.
/// - A host network change (`networkChanged`) brings the next check forward.
/// - The user can resume an OS by hand (`resumeNow`).
///
/// `@MainActor` for the same reason as `HostBudget`: every caller is already
/// main-actor isolated, so decisions stay synchronous.
@MainActor
public final class LaunchGate {
  public struct Policy: Equatable, Sendable {
    /// Consecutive launch failures (no runner reaching GitHub in between) that
    /// pause the OS. Two matches the old `launchFailing` badge: one failure is
    /// noise, two in a row is a pattern.
    public var failureThreshold: Int
    /// Wait before the first retry after a failed check; doubles per failed
    /// check up to `maxBackoff`.
    public var initialBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    /// How long a probe or trial may stay unanswered before it counts as lost
    /// (its fleet was retired mid-boot, or a hung probe never returned).
    public var outstandingTimeout: TimeInterval

    public init(
      failureThreshold: Int = 2, initialBackoff: TimeInterval, maxBackoff: TimeInterval,
      outstandingTimeout: TimeInterval
    ) {
      self.failureThreshold = max(1, failureThreshold)
      self.initialBackoff = max(0, initialBackoff)
      self.maxBackoff = max(self.initialBackoff, maxBackoff)
      self.outstandingTimeout = max(0, outstandingTimeout)
    }

    /// Linux and macOS checks are cheap (a container probe, or one host-process
    /// runner that registers in seconds): retry within a minute, never wait
    /// more than five. A Windows trial is a full linked-clone boot (4–7 min to
    /// register), so its retries are spaced to match and its trial gets the
    /// 10-minute never-confirmed window plus slack.
    public static func standard(for os: RunnerOS) -> Policy {
      switch os {
      case .windows:
        return Policy(initialBackoff: 5 * 60, maxBackoff: 20 * 60, outstandingTimeout: 15 * 60)
      case .linux, .macOS:
        return Policy(initialBackoff: 60, maxBackoff: 5 * 60, outstandingTimeout: 5 * 60)
      }
    }

    /// `initialBackoff × 2^level`, capped at `maxBackoff`.
    public func backoff(level: Int) -> TimeInterval {
      let exponent = Double(min(max(level, 0), 16))
      return min(maxBackoff, initialBackoff * pow(2, exponent))
    }
  }

  public enum Decision: Equatable, Sendable {
    /// Launch as demand requires.
    case allowed
    /// Paused, but one trial launch is due: provision at most ONE runner, mark
    /// it as the trial when reporting its outcome, and call `releaseTrial` if
    /// it could not be launched at all.
    case trial
    /// Paused: launch nothing this tick.
    case paused
  }

  /// What the UI shows for a paused OS.
  public struct Pause: Equatable, Sendable {
    public var os: RunnerOS
    public var since: Date
    /// Why launches stopped, in words: the probe's finding when there is one,
    /// else the last launch failure.
    public var reason: String
    /// A probe or trial is running right now.
    public var checking: Bool
    /// When the next check is due; `nil` while one is running.
    public var nextCheckAt: Date?
    /// The OS is checked with a network probe; otherwise with a trial launch.
    public var checksByProbe: Bool
  }

  /// A probe's verdict on whether runners of an OS could reach GitHub.
  public struct ProbeResult: Equatable, Sendable {
    public var reachable: Bool
    /// One sentence for the user, e.g. why the network check failed.
    public var detail: String

    public init(reachable: Bool, detail: String) {
      self.reachable = reachable
      self.detail = detail
    }
  }

  public typealias Probe = @Sendable () async -> ProbeResult

  private struct State {
    var consecutiveFailures = 0
    /// Failed checks since the last runner reached GitHub; drives the backoff.
    var level = 0
    var paused = false
    var since = Date.distantPast
    var reason = ""
    var retryAt = Date.distantPast
    var probing = false
    var trialOutstanding = false
    var outstandingSince: Date?
    /// The host network changed while a check was running, so a failed result
    /// may describe the old network: check again at once instead of backing off.
    var networkChangedDuringCheck = false
    /// Invalidates a probe result that lands after the state it was started
    /// for (a runner confirmed online meanwhile, or the probe went stale).
    var probeGeneration = 0
  }

  private var states: [RunnerOS: State] = [:]
  private var probes: [RunnerOS: Probe] = [:]
  private let policies: [RunnerOS: Policy]
  private let clock: @MainActor () -> Date

  /// Fired whenever a pause starts, changes, or ends (UI refresh).
  public var onChange: (() -> Void)?
  /// Fired when a paused OS may launch again because its probe passed or the
  /// user resumed it, so the app can nudge that OS's fleets instead of waiting
  /// for their next tick.
  public var onResume: ((RunnerOS) -> Void)?

  public init(
    policies: [RunnerOS: Policy] = [:],
    clock: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.policies = policies
    self.clock = clock
  }

  public func policy(for os: RunnerOS) -> Policy { policies[os] ?? .standard(for: os) }

  /// Install (or clear) the network probe for an OS. With a probe, a paused OS
  /// resumes on a passing probe; without one, it resumes through trial launches.
  public func setProbe(_ probe: Probe?, for os: RunnerOS) {
    probes[os] = probe
  }

  /// The current pause for `os`, or `nil` when it may launch freely.
  public func pause(for os: RunnerOS) -> Pause? {
    guard let state = states[os], state.paused else { return nil }
    let checking = state.probing || state.trialOutstanding
    return Pause(
      os: os, since: state.since, reason: state.reason, checking: checking,
      nextCheckAt: checking ? nil : state.retryAt, checksByProbe: probes[os] != nil)
  }

  public var pauses: [Pause] {
    RunnerOS.allCases.compactMap { pause(for: $0) }
  }

  /// Ask before launching, and only when there is a runner to launch: a paused
  /// OS whose check is due starts its probe here (the caller just sees
  /// `.paused`) or hands out a single trial.
  public func decision(for os: RunnerOS) -> Decision {
    guard var state = states[os], state.paused else { return .allowed }
    let now = clock()

    if let since = state.outstandingSince,
      state.probing || state.trialOutstanding,
      now.timeIntervalSince(since) >= policy(for: os).outstandingTimeout
    {
      // The check never answered. Count it as failed and schedule the next.
      ControlPlaneLog.log(
        "launch_gate.check_lost",
        ["os": os.rawValue, "kind": state.probing ? "probe" : "trial"])
      state.probing = false
      state.trialOutstanding = false
      state.outstandingSince = nil
      state.networkChangedDuringCheck = false
      state.probeGeneration += 1
      scheduleRetry(&state, os: os, now: now)
      states[os] = state
      notifyChange()
    }

    guard !state.probing, !state.trialOutstanding, now >= state.retryAt else { return .paused }

    if let probe = probes[os] {
      state.probing = true
      state.outstandingSince = now
      state.probeGeneration += 1
      let generation = state.probeGeneration
      states[os] = state
      ControlPlaneLog.log(
        "launch_gate.probe_start", ["os": os.rawValue, "level": String(state.level)])
      Task { [weak self] in
        let result = await probe()
        self?.finishProbe(os, generation: generation, result: result)
      }
      notifyChange()
      return .paused
    }

    state.trialOutstanding = true
    state.outstandingSince = now
    states[os] = state
    ControlPlaneLog.log("launch_gate.trial", ["os": os.rawValue, "level": String(state.level)])
    notifyChange()
    return .trial
  }

  /// A `.trial` the caller could not launch (budget denied, JIT minting
  /// failed): nothing was tested, so the next tick may try again.
  public func releaseTrial(_ os: RunnerOS) {
    guard var state = states[os], state.trialOutstanding else { return }
    state.trialOutstanding = false
    state.outstandingSince = nil
    state.networkChangedDuringCheck = false
    states[os] = state
    notifyChange()
  }

  /// A runner of `os` failed to launch: it exited or could not start during
  /// launch, or it was reaped for never reaching GitHub. `trial` says the
  /// runner was launched for a `.trial` decision.
  public func recordLaunchFailure(_ os: RunnerOS, reason: String, trial: Bool = false) {
    var state = states[os] ?? State()
    let now = clock()
    state.consecutiveFailures += 1

    if state.paused {
      // Keep the probe's finding as the reason while it is the newer news.
      if probes[os] == nil { state.reason = reason }
      if trial, state.trialOutstanding {
        // The trial failed: wait longer before the next one (or check again at
        // once when the network changed while it booted).
        state.trialOutstanding = false
        state.outstandingSince = nil
        retryAfterFailedCheck(&state, os: os, now: now)
        ControlPlaneLog.log(
          "launch_gate.trial_failed",
          [
            "os": os.rawValue, "level": String(state.level),
            "reason": String(reason.prefix(200)),
          ])
      }
      // Otherwise this is a runner launched before the pause, failing late:
      // it is not a new attempt, so it does not grow the backoff.
      states[os] = state
      notifyChange()
      return
    }

    guard state.consecutiveFailures >= policy(for: os).failureThreshold else {
      states[os] = state
      return
    }
    state.paused = true
    state.since = now
    state.reason = reason
    state.networkChangedDuringCheck = false
    if probes[os] != nil, state.level == 0 {
      // First pause since a runner last reached GitHub: check the network now,
      // so the user learns why at once instead of after a backoff.
      state.retryAt = now
    } else {
      // A repeat pause (the probe passed but runners still failed) waits out
      // the backoff, so a broken setup costs one launch per backoff period.
      scheduleRetry(&state, os: os, now: now)
    }
    states[os] = state
    ControlPlaneLog.log(
      "launch_gate.pause",
      [
        "os": os.rawValue, "failures": String(state.consecutiveFailures),
        "level": String(state.level), "reason": String(reason.prefix(200)),
      ])
    notifyChange()
  }

  /// A runner of `os` reached GitHub: launches work, so clear everything.
  public func recordLaunchSuccess(_ os: RunnerOS) {
    guard let state = states[os] else { return }
    let wasPaused = state.paused
    var cleared = State()
    cleared.probeGeneration = state.probeGeneration + 1  // drop any in-flight probe
    states[os] = cleared
    if wasPaused {
      ControlPlaneLog.log("launch_gate.resume", ["os": os.rawValue, "by": "runner_online"])
      notifyChange()
    }
  }

  /// The user asked to launch again now. One more failure pauses again, and
  /// the backoff carries on from where it was: the manual resume is not a
  /// check, so it neither resets the backoff nor grows it.
  public func resumeNow(_ os: RunnerOS) {
    guard var state = states[os], state.paused else { return }
    state.paused = false
    state.probing = false
    state.trialOutstanding = false
    state.outstandingSince = nil
    state.networkChangedDuringCheck = false
    state.probeGeneration += 1  // ignore a probe still running
    state.consecutiveFailures = max(0, policy(for: os).failureThreshold - 1)
    state.reason = ""
    states[os] = state
    ControlPlaneLog.log("launch_gate.resume", ["os": os.rawValue, "by": "user"])
    notifyChange()
    onResume?(os)
  }

  /// The host's network path changed (Wi-Fi joined, VPN up or down, wake). A
  /// paused OS checks again now instead of at its backoff time; a check that is
  /// running is repeated if it fails, since it may have tested the old network.
  /// The failure history is kept, so a check that still fails continues the
  /// backoff.
  public func networkChanged() {
    let now = clock()
    var changed = false
    for (os, var state) in states where state.paused {
      if state.probing || state.trialOutstanding {
        state.networkChangedDuringCheck = true
      } else {
        state.retryAt = now
        changed = true
      }
      states[os] = state
      ControlPlaneLog.log("launch_gate.network_change", ["os": os.rawValue])
    }
    if changed { notifyChange() }
  }

  private func finishProbe(_ os: RunnerOS, generation: Int, result: ProbeResult) {
    guard var state = states[os], state.paused, state.probing,
      state.probeGeneration == generation
    else { return }
    let now = clock()
    state.probing = false
    state.outstandingSince = nil
    ControlPlaneLog.log(
      "launch_gate.probe_result",
      [
        "os": os.rawValue, "reachable": String(result.reachable),
        "detail": String(result.detail.prefix(200)), "level": String(state.level),
      ])
    if result.reachable {
      // Launch again, but stay one failure from re-pausing, at a longer
      // backoff: if runners still cannot register, the network was not the
      // cause and the next pause must not turn straight back into a loop.
      state.paused = false
      state.networkChangedDuringCheck = false
      state.consecutiveFailures = max(0, policy(for: os).failureThreshold - 1)
      state.level += 1
      state.reason = ""
      states[os] = state
      notifyChange()
      onResume?(os)
      return
    }
    state.reason = result.detail
    retryAfterFailedCheck(&state, os: os, now: now)
    states[os] = state
    notifyChange()
  }

  /// A probe or trial failed. If the network changed while it ran, the result
  /// may be about the old network: check again on the next decision, at the
  /// same backoff level. Otherwise back off.
  private func retryAfterFailedCheck(_ state: inout State, os: RunnerOS, now: Date) {
    if state.networkChangedDuringCheck {
      state.networkChangedDuringCheck = false
      state.retryAt = now
    } else {
      scheduleRetry(&state, os: os, now: now)
    }
  }

  /// Push the next check out by the current backoff, then grow it.
  private func scheduleRetry(_ state: inout State, os: RunnerOS, now: Date) {
    state.retryAt = now.addingTimeInterval(policy(for: os).backoff(level: state.level))
    state.level += 1
  }

  private func notifyChange() { onChange?() }
}
