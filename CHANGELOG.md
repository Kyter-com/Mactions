# Changelog

All notable changes to Mactions are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [0.1.5] - 2026-06-29

### Fixed

- **Runner activity spinner froze into a static "spoke wheel" while a job was
  running.** The dashboard's per-runner busy indicator used a native circular
  `ProgressView`, whose underlying `NSProgressIndicator` stops animating once its
  row is recycled in the virtualized fleet list — so a running job showed a
  frozen macOS spoke wheel instead of the GitHub-style spinning ring. Replaced it
  with a Core-Animation-driven arc: the rotation runs on the render server
  (independent of the main thread, so it adds no per-frame work however large the
  fleet), survives list-row recycling without freezing, tracks light/dark
  appearance, and honors Reduce Motion.

## [0.1.4] - 2026-06-27

### Added

- **Control-plane logging.** Structured logging — an OSLog subsystem
  (`com.kyter.mactions`) plus an append-only, size-rotated
  `~/.mactions/logs/control-plane.jsonl` — now traces the all-repositories
  discovery scan (begin/provision/reap/end and watchdog timeouts) and the
  orchestrator's provisioning path (budget-denied, launch outcome, `listRunners`
  outage hold). A provisioning stall is now explainable from the log alone, and a
  missing scan-end line pinpoints a freeze. Motivated by a ~9.5 h all-OS
  provisioning stall that previously left no runtime trace.
- **Discovery-loop watchdog.** Each discovery scan now runs in a structured task
  group raced against a 180 s timer; a hung scan is cancelled so the loop always
  ticks again, while go-offline cancellation still propagates promptly.

### Fixed

- **Unbounded control-plane API timeouts.** Both GitHub API clients defaulted to
  `URLSession.shared`, whose `timeoutIntervalForResource` is 7 days — so a single
  wedged connection could hang a request (and the discovery loop awaiting it)
  almost indefinitely. The control-plane session now caps the request timeout at
  30 s and the resource timeout at 60 s.

## [0.1.3] - 2026-06-16

### Fixed

- **Linux runner containers could pile up when a runner never reached GitHub.**
  If an ephemeral Linux container registered but never connected — e.g. its
  network egress failed — it never exited, so the orchestrator dropped it from
  tracking and launched a replacement every reap cycle, accumulating zombie
  containers (15 observed in one incident) that exhausted Apple `container`'s
  shared vmnet NAT bridge and wedged the network for the rest.

  Root cause: `LinuxContainerProvider.stop()` only SIGTERM'd the foreground
  `container run` client (an attachment to the daemon-managed container) and
  relied on its termination handler to force-delete the container — which did
  not fire reliably, so the container kept running. `stop()` now force-deletes
  the container by name directly (`container delete --force`, verified to reap a
  running container), so every reap actually removes its container.

### Added

- **Liveness reaper for "registered but never online" runners.** A runner alive
  past `neverConfirmedReapInterval` (default 2 min) that GitHub never once
  confirmed `online` is force-deleted, deregistered, and counted toward the
  launch-failure backoff — rather than waiting out the 5-minute sustained-offline
  grace (which exists to protect a mid-job runner from a transient blip). A
  repeated failure now flips `launchFailing` ("substrate broken") instead of
  respawning forever.
- **Bridge-safe Linux concurrency ceiling** (`maxConcurrentContainersCeiling`,
  default 4). The effective per-host container cap is the lower of the RAM/CPU
  divide and this ceiling, because Apple `container`'s single shared vmnet NAT
  bridge — not RAM/CPU — is the binding constraint past a handful of containers.
- **Sustained runner-API outage backstop.** When `listRunners` has been failing
  for a sustained window, the orchestrator holds the fleet instead of scaling up
  against unknown busy-ness (which, during an egress outage, would spawn
  replacements that can never connect).
