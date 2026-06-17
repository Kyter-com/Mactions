# Changelog

All notable changes to Mactions are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

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
