# AGENTS.md — Mactions

Guide for humans and AI agents working in this repo. Read this before making changes.

Sibling docs: **[BASE.md](docs/BASE.md)** (runner-environment philosophy: provide runner/OS semantics and leave convenience tools to workflows), **[PARITY.md](docs/PARITY.md)** (the current per-OS contract vs GitHub-hosted runners; update it when runner-visible behavior changes), and **[WINDOWS.md](docs/WINDOWS.md)** (Windows architecture, build recipe, history, and compatibility findings).

## What this is

**Mactions** is a native macOS app that turns your Mac into an **on-demand, ephemeral GitHub Actions runner host**. Open the app and it watches your repos for queued jobs, starting self-hosted runners on demand (scale-from-zero — zero runners is the normal idle state); quit it and the watching stops. Each runner is single-use (JIT / `--ephemeral`): it registers, runs exactly one job, deregisters, and is torn down — replaced only while matching jobs remain queued.

Think of it as a laptop-scale, multi-OS, app-controlled version of [actions-runner-controller](https://github.com/actions/actions-runner-controller). The novel part is the UX: "runners exist while the app is open."

### Why it exists

A private downstream CI repo leans on self-hosted runners while the GitHub-hosted `windows-latest` / `macos-latest` arms have been failing at runner allocation. Mactions is a way to self-host macOS, Windows, and Linux runners from a Mac you already have, with a friendly on/off switch.

## Status

Proof-of-concept. Honest accounting:

- ✅ **Core control loop** (auth → queued-jobs poll → JIT config → provider → ephemeral runner → demand-gated replace/trim → teardown) is implemented and unit-tested — **scale-from-zero** (2026-06-10, issue #41): runners exist only while matching jobs are queued.
- ✅ **Auth, three ways:** one-click **GitHub CLI** reuse (`gh auth token`), device-flow sign-in, or paste-a-PAT. Token stored in a `0600` file (not the keychain — see Auth for why).
- ✅ **Searchable multi-repo picker** (lists repos you can admin) + one ephemeral fleet per selected repo, run concurrently.
- ✅ **Local-process provider**: runs the actions-runner agent directly on the Mac (no VM isolation, but each run is an isolated clone that's wiped on exit — see Host hygiene). This is the runnable MVP path.
- ✅ **SwiftUI/AppKit dashboard app**: status, config, online/offline, live runner list; deregisters on quit.
- ✅ **Primary dashboard window** (`DashboardWindowController` — AppKit `NSWindow` hosting SwiftUI). A **Pulse-style console** with **Runners / History / Memory** tabs in a master–detail layout:
  - **History** records completed/failed runs (persisted to `~/.mactions/logs/run-history.json`, survives restarts). Selecting a run fetches its **GitHub Actions job log** via the REST API and shows it **inline** (monospaced, line-numbered, searchable) — correlated to the run by the unique `mactions-…` runner name, so it works across **macOS, Windows, and Linux** (logs live on GitHub, sidestepping provider-specific capture). Correlation happens promptly on runner exit and persists the stable GitHub job id with the history row; legacy rows use a time-bounded paginated recovery scan, so newer workflow runs or an app restart cannot strand retained logs. Freshly-finished conclusions and GitHub's normal log-indexing 404 both get bounded settlement retries; transport failures surface as errors rather than empty logs. Parsed logs use an eight-entry LRU, Actions clients use a 64-repo LRU, and ETag bodies are entry/byte bounded. Auth/history generations prevent canceled old requests from repopulating state after sign-out or Clear. Teardown reaps aren't recorded; only runs that finish on their own while online are.
  - **Runners** shows the live fleet; selecting a runner polls its current job's **step checklist** (Jobs API `steps`). Initial correlation uses the runner's real provider launch time (so multi-hour jobs remain discoverable) and searches compact active-run listings first. After correlation, each 4-second refresh uses the direct job endpoint with ETags (not another recent-runs scan), bypassing GitHub's 60-second URL cache while keeping unchanged 304s free against the primary rate limit. The 6-second busy-dot poll only touches repos that currently have visible runners, and runner-list pages are ETagged too; scale-zero repos consume no dashboard polling quota. Completed runners' checklist state is pruned. `gh run watch` is deliberately not embedded (issue #38): it watches a known workflow run rather than a unique ephemeral runner/job, shows step state rather than streaming log lines, and does not support fine-grained PATs.
  - **Memory** is a **live** gauge + sparkline + per-bucket RSS (Windows VMs / local runners / app), via `MemorySampler` (Mach `host_statistics64` + `ps`), sampled **only while the window is open**; Linux VM usage is included in the host total but is not yet attributed to a separate bucket.
  - **Windowed, still fleet-safe** — the dashboard opens on launch and closing the window never quits or takes runners offline. **Liquid Glass** (macOS 26+, `#available`-guarded, material fallback) on the control layer (chips in a `GlassEffectContainer`, search fields, buttons) — never on content, never glass-on-glass.
  - **OS-logo tiles** render from **custom SF Symbol** templates staged as a `.symbolset` (`Sources/Mactions/Media.xcassets`). `swift build` doesn't run `actool`, so `OSLogo` prefers the compiled symbol when present and falls back to drawing the identical `Regular-S` glyph via a tiny SVG-path parser (`SVGSymbol`); it upgrades to true SF Symbols once packaged as a real `.app`.
  - **Performance contract:** all slow work (GitHub fetches, `ps`, VMX reads, log parsing) runs off the main actor (nonisolated async / detached); the views only read published state, so the Mac UI never stutters.
- 🟢 **Windows provider** (`WindowsVMProvider`): **PROVEN END TO END on VMware Fusion (2026-06-01).** Fusion is the sole backend, the base build is automated, every job uses a linked clone, and recipe v14 verifies guest outcomes before teardown; see [Windows support](#windows-support).
- 🟢 **Linux provider** (`LinuxContainerProvider`): **PROVEN END TO END (2026-06-08).** Each job runs the official arm64 Actions runner image through Apple `container` inside its own lightweight VM, with the writable layer destroyed by `--rm`; see [Linux support](#linux-support).

## Architecture

Two SwiftPM targets so orchestration logic stays UI-free and testable:

```
MactionsCore (library, pure Foundation)        Mactions (executable, SwiftUI/AppKit)
  GitHubAuth      device flow + PAT + token file   MactionsApp   @main, AppDelegate
  GitHubCLIAuth   reuse `gh auth token`            AppState      glue: one orchestrator per
  GitHubClient    jitconfig/list/delete + actions runs/jobs/logs  selected repo
  RepoLister      list admin repos (the picker)    SettingsRootView  GitHub + platform setup
  RunnerInstaller downloads the runner agent       DashboardWindowController  primary app window
  Providers       Local + Windows + Linux + factories  DashboardView  Pulse-style console: runners / history+inline GH logs / live memory
  LinuxContainer* provider + budget + image + setup-progress (container-per-job)
  Orchestrator    start/stop/scale-from-zero (+ run-finished events)  OSLogo  custom-SF-Symbol tiles (+ SVGSymbol glyph fallback)
  HostBudget      live shared Windows/Linux capacity ledger (acquired per provision)
  RunHistory      RunRecord + on-disk run-history store (~/.mactions/logs)
  MemorySampler   host (host_statistics64) + per-process RSS (ps) → Memory tab
  WindowsPreflight prereq detect (Fusion + converters + xorriso) + brew installer
  WindowsImage    UUP-dump latest-ISO resolve + build-id auto-update
  Cleanup, Shell  host hygiene + process helper        Media.xcassets  staged custom SF Symbols (compile in a real .app)

  WindowsVMCLI impl (sole backend):
    VMwareCLI     VMware Fusion via vmrun (driven by the mactions-fusion-vm helper)
scripts/                                       (driven by AppState + provider)
  prepare-windows-image     UUP-dump → ISO + no-prompt remaster + unattend ISO
  fusion-windows-base       headless Win11-ARM base build via vmrun (+ snapshot)
  mactions-fusion-vm        per-clone vmrun lifecycle (clone/start/stop/delete/...)
  autounattend.xml, bootstrap.ps1  unattended Setup + base-image bootstrap
```

**The loop** (`RunnerOrchestrator`) — **SCALE-FROM-ZERO** (2026-06-10; issue #41). Runners exist only while queued jobs need them; **zero runners is the normal armed state** (the old model — keep `desiredCount` warm + an 8-min idle-JIT churn — is gone):

1. Each reconcile tick (30s active / 60s idle-at-zero) reads GitHub's runner list (busy/idle health), then polls the repo's **queued jobs**: job-level status across runs in BOTH `queued` and `in_progress` states (run-level status flaps; an in_progress run can carry queued matrix legs), freshness-filtered on `max(created_at, updated_at)` (re-runs keep the original `created_at`). ETag conditional requests make the idle poll free against the rate limit (304s aren't billed).
2. Demand = queued jobs whose labels ⊆ this combo's labels (GitHub's cumulative `runs-on` rule, case-insensitive). Target = `min(busy + matchingQueued, maxRunners)`, where `maxRunners` (the per-combo count, 1–5) is a **ceiling**, not a floor. A **failed poll HOLDS the fleet** — never scale on missing info.
3. Scale-up: mint `generateJITConfig` → `RunnerProvider.start` per shortfall, each drawing on the live shared `HostBudget` (Windows RAM / Linux RAM+CPU, host-wide, refunded on every exit). The agent registers, runs **one** job, deregisters, exits; `onExit` → re-reconcile (demand-gated — no blind replace).
4. Scale-down: surplus confirmed-idle runners (job taken elsewhere / cancelled) are trimmed after a two-snapshot grace, **deregister-first** (GitHub refuses to delete a busy runner — the server-side race guard), then stopped; trims/reaps never land in run history (`reaped` flag).
5. `stop()` deregisters **this orchestrator's own runners** (never a machine-prefix sweep — sibling combos keep running under all-repos discovery), then tears down providers. Crash ghosts are reaped by the go-online sweep + GitHub's 1-day auto-prune.
6. Optional **all-repos discovery** (`FleetPlan.allRepos`): while online, AppState scans the ~50 most-recently-pushed admin repos each minute and lazily creates (then quiet-reaps) orchestrators seeded from the default platforms.

**Lifecycle:** the app is a regular windowed macOS app. Closing the dashboard leaves the app and fleet running; quitting is the "go offline" signal. `AppDelegate.applicationShouldTerminate` returns `.terminateLater`, runs `goOfflineAndWait()`, then replies — with a 6s hard timeout so a hung network call can't wedge quit. Ephemeral runners + GitHub's offline sweep are the backstop for force-quit/crash.

## Providers

`RunnerProvider` is the substrate one runner executes on.

- **`LocalProcessProvider`** — runs the agent as a child process on the Mac. No isolation. Fine for **trusted private repos**. This is the fastest path and always available on a Mac.
- **`WindowsVMProvider`** — linked-clones a pristine Win11-ARM base VM, injects a per-clone config ISO (copied to the clone's wired `sata0:0` CD), boots it headless, and redundantly copies the same JIT through VMware Tools to `C:\setup\jitconfig`. The guest reads either channel, runs `run.cmd --jitconfig …` for one job + writes an infrastructure outcome + self-powers-off; the host verifies that outcome through Tools (capturing `run-job.log` on failure), polls power state, and **deletes the clone on exit**. Backed by a `WindowsVMCLI` abstraction with **`VMwareCLI`** (VMware Fusion via the `mactions-fusion-vm` helper) as its sole conformer — the proven Win11-ARM backend. `WindowsVMProviderFactory.detectInstalledCLI()` returns it when Fusion (`vmrun`) + the helper are present. See [Windows support](#windows-support).
- **`LinuxContainerProvider`** — the simplest provider lifecycle: `start()` runs `container run --rm … /home/runner/run.sh` as a foreground `Process` (JIT via the `ACTIONS_RUNNER_INPUT_JITCONFIG` env, not the arg list), and the process's exit code is the completion signal, so there is no provider-managed boot/job/stop polling or config ISO. Apple `container` backs each container with its own lightweight VM and guest Linux kernel; Mactions still limits this proof-of-concept self-hosted path to trusted/private repos. See [Linux support](#linux-support).

### Per-OS reality (important)

- **macOS:** local process only. No macOS VM fallback is shipped.
- **Linux:** implemented as a **container per job** (`LinuxContainerProvider`) rather than a full VM — `--rm` gives the cleanest ephemerality. On Apple Silicon the container is **arm64**, so the fleet registers `[self-hosted, Linux, ARM64, mactions]` (the **`ARM64`** label is deliberate: `ubuntu-latest` is x64, so workflows must opt into the arm64 runner by label, and `RUNNER_ARCH=ARM64`). Apple `container` is the sole backend.
- **Windows guests:** the hard one, handled via `WindowsVMProvider` on **VMware Fusion** (see [Windows support](#windows-support)). On Apple Silicon only **Windows 11 ARM** runs; x64 is emulation-only and slow. The provider linked-clones a throwaway Win11-ARM VM per job and destroys it after — the only way to hit the ephemerality bar on Windows (no APFS-clone HOME-redirect trick exists there).

## Windows support

> ✅ **PROVEN END TO END.** VMware Fusion is the sole backend: the app builds a
> provisioned Win11-ARM base, launches one linked clone per queued job, verifies
> the guest's infrastructure outcome, and deletes the clone after the ephemeral
> runner exits.

The detailed architecture, automated base recipe, backend investigation,
incident history, downstream compatibility findings, and remaining Windows work
live in **[WINDOWS.md](docs/WINDOWS.md)**; the user-visible differences from
GitHub-hosted runners live in **[PARITY.md](docs/PARITY.md)**.

Current contributor invariants:

- Windows setup is opt-in and button-gated; no ISO download or base build starts
  automatically.
- `VMwareCLI` is the sole `WindowsVMCLI` conformer and
  `scripts/mactions-fusion-vm` owns clone/start/status/stop/delete mechanics.
- Every job receives its JIT through the config ISO plus the VMware-Tools
  fallback, and recipe v14 requires a verified `success` outcome before guest
  power-off can map to exit 0.
- Keep guest PowerShell pure ASCII with a UTF-8 BOM, write the provisioning
  sentinel last, and bump the script and Swift recipe constants together when a
  guest change makes existing bases stale.
- A missing base blocks the Windows fleet, while a stale base remains usable and
  surfaces a rebuild nudge.
- Workflows must use `runs-on: [self-hosted, Windows, mactions]`; hosted labels
  do not route to Mactions.

## Linux support

> ✅ **PROVEN END TO END (2026-06-08).** Through the real app UI, an ephemeral **arm64 container** runner registered **outbound** to GitHub and ran a **green** Linux job (`RUNNER_OS=Linux`, `RUNNER_ARCH=ARM64`, `aarch64`, Ubuntu 24.04.4, user `runner`) on a private test repo, then auto-deregistered and the container was destroyed (`--rm`) — host left clean, fleet reconciled a fresh replacement while online. Job's Go came from `actions/setup-go` (`go1.26.4 linux/arm64`), not the base image — exactly the [BASE.md](docs/BASE.md) philosophy.

Linux is the **simplest provider lifecycle** of the three OSes: Apple `container` creates a lightweight VM-backed throwaway container per job, while Mactions only manages the foreground container process and has none of the Windows base-build, config-ISO, or power-state machinery.

### How it works (the per-job loop)

1. **Image** — `ghcr.io/actions/actions-runner` (official, multi-arch; the native `linux/arm64` variant runs without emulation). Built `FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble`, so the agent's native deps (libicu/libssl/libkrb5/zlib) are pre-baked — no in-guest `installdependencies.sh`. Acquired by `container image pull` (seconds) and refreshed via a `.linux-image-version` sentinel, the analog of `RunnerInstaller` refreshing the macOS agent template. **Per [BASE.md](docs/BASE.md) it stays minimal** — no Go/Node/etc.; workflows add their own toolchain with `setup-*`.
2. **JIT** — the orchestrator mints `generate-jitconfig` (the *same* encoded value that drives `run.sh` on macOS/Windows) right before `start()`.
3. **Run** — `container run --rm --name mactions-<id> --label mactions --cpus N --memory NG -e ACTIONS_RUNNER_INPUT_JITCONFIG <image> /home/runner/run.sh`, as a foreground Foundation `Process`. The JIT rides in via the **env var** (`CommandSettings` strips the `ACTIONS_RUNNER_INPUT_` prefix → `--jitconfig`) so the secret never lands in `ps`. The image has **no entrypoint** (its default `Cmd` is `/bin/bash`, which would do nothing), so the explicit `run.sh` command is required.
4. **Completion** — the foreground process exits with the container's exit code → `onExit(status)` fires directly (identical to `LocalProcessProvider`). No polling threads.
5. **Teardown** — `--rm` discards the container; `cleanup()` also force-deletes by name (a SIGKILL or a killed CLI client *can* orphan a container — confirmed live), and `HostCleanup.purgeStrayLinuxContainers()` reaps `mactions-` leftovers on go-online (the analog of `purgeStrayWindowsClones`).

### Backends (`LinuxContainerCLI`, presence-detected like Fusion)

A pure command-builder protocol (`runArgs`/`stopArgs`/`rmArgs`/`inspectArgs`/`pullArgs`/`imageInspectArgs`/`daemonStatusArgs`/`daemonStartArgs`/`sweepListArgs`) so the per-tool shapes are unit-testable without a live daemon. `detectInstalledCLI()` returns Apple `container` only on arm64 macOS 26+:

- **`ContainerCLI`** (Apple `container`, **macOS 26+**, arm64) — Apache-2.0, one lightweight VM per container. **Validated live on 0.12.3 (macOS 26.5.1):** `run --rm/--name/--label/--cpus/--memory 6g/-e KEY` (env pass-through) + trailing `run.sh` all work. Installed via the **signed `.pkg` from github.com/apple/container/releases** at `/usr/local/bin/container`. Two backend-specific notes the code handles: (1) first use installs a **default Linux kernel** once (`system kernel set --recommended` — `system start` only prompts for it; gated since it's not idempotent), and (2) `container list` has **no `--filter`**, so the orphan sweep scopes by the `mactions-` name prefix instead of the label.

### Concurrency, labels, isolation

- **Cap** — `LinuxContainerBudget.maxConcurrentContainers` binds on the tighter of `(RAM_GB − 4) / 6` and `cores / 2`, with a hard `--cpus 2 --memory 6g` per container. Far looser than the Windows VM RAM budget because these lightweight VMs start in under a second.
- **Labels** — `[self-hosted, Linux, ARM64, mactions]`. The **`ARM64`** is the one real gotcha: a Mac runner is arm64 while `ubuntu-latest` is x64, so workflows must opt in (`runs-on: [self-hosted, Linux, ARM64, mactions]`); arch-sensitive prebuilt-binary steps can differ from hosted x64 (cf. the `workerd` win-arm64 note under Windows).
- **Isolation** — each container has its own lightweight VM and guest Linux kernel, but Mactions still permits **trusted/private repos only** because jobs execute on a personal self-hosted machine and Apple `container` remains an evolving security boundary. Do not route untrusted/public/fork jobs here; Docker-in-workflow (`jobs.<id>.container` / mounting `/var/run/docker.sock`) is unsupported.

## Auth

Friendly by design — no env vars, no hand-copied long tokens.

- **GitHub CLI (easiest):** reuse the token `gh` already holds (`gh auth token`). One click, no setup, nothing to paste — ideal for any dev who has `gh`. `GitHubCLIAuth`.
- **Device flow:** show a short user code, open `github.com/login/device`, poll for approval. Needs a registered **OAuth App client id** (not a secret; device flow has none) — bake one in (or paste it in Settings). This is how a signed app gives zero-per-user-setup sign-in once the client id ships.
- **PAT fallback:** paste a token. Works immediately, no OAuth App needed.
- **Scope:** `repo` (classic), or fine-grained **Administration: read & write** plus **Actions: read-only** on the target repo — Administration registers/removes repo self-hosted runners; Actions powers the live step checklist and History/log correlation.
- **Storage:** a `0600` file at `~/.mactions/auth.token`, cached in memory — **not** the login keychain. An unsigned/dev build has no stable code identity, so the keychain re-prompts on every read, "Always Allow" won't stick, and the modal can steal focus from the app (cancelling in-flight requests). A sibling app makes the same file-based choice. A signed/notarized build could move back to the keychain — see Roadmap.

## Build / run / test

```bash
swift build          # compiles MactionsCore + the app
swift test           # 241 unit tests (requests, Actions job/run pagination/direct refresh + ETags, device-flow guard, queued-jobs polling, repo lister, scale-from-zero orchestrator, host budget, shared repo control plane + discovery ledger, cleanup, run-scoped agent teardown, Windows VM command shapes + image/preflight logic, Linux container command shapes + budget + setup-progress, RunnerOS labels)
swift run Mactions   # launches the app for dev
```

`swift run` is fine for development; the Xcode app target provides the real AppIcon and release packaging path.

### Exporting the real app icon

The Liquid Glass/3D icon is produced by Xcode's Icon Composer pipeline from
`Sources/Mactions/Mactions.icon`. Do **not** recreate it from `Group.svg` or
`AppLogo.image(...)` for README/social assets — those are fallback/compositing
paths and miss the compiled glow/depth treatment.

To refresh `docs/assets/mactions-logo.png`, build the Xcode app target and
extract the compiled `.icns`:

```bash
xcodebuild -project Mactions.xcodeproj \
  -scheme MactionsApp \
  -configuration Debug \
  -derivedDataPath /tmp/MactionsDerived \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf /tmp/mactions-icon.iconset
iconutil -c iconset \
  /tmp/MactionsDerived/Build/Products/Debug/Mactions.app/Contents/Resources/Mactions.icns \
  -o /tmp/mactions-icon.iconset

cp /tmp/mactions-icon.iconset/icon_128x128@2x.png docs/assets/mactions-logo.png
```

`icon_128x128@2x.png` is the useful README size: rendered by the real app-icon
compiler, small enough for git, and sharp at the README's 112 px display width.

**CI:** there's deliberately no branch push-triggered CI. GitHub-hosted `macos-latest` runners aren't available to the Kyter-com org (jobs get no runner and fail in ~4s), and a self-hosted runner only exists while someone has Mactions open — neither is reliable for push CI. So validation is local `swift test` plus the manual smoke workflows (`macos-smoke.yml`, `linux-smoke.yml`, `windows-smoke.yml`), which prove Mactions-provided runners on each platform. Releases are the exception: `.github/workflows/release.yml` runs on a Mactions-provided macOS runner for version tags/manual dispatch, builds the Xcode app target, signs/notarizes, generates the Sparkle appcast, and publishes the GitHub release.

## Host hygiene (no leftover crap)

Ephemeral means the host is left as it was found. This is enforced, not hoped for — see `Cleanup.swift` and `LocalProcessProvider`:

- **Everything Mactions writes lives under one directory:** `~/.mactions/` (the cached agent template + a `runs/` dir + the token). A dot-dir in `$HOME`, **not** `~/Library/Application Support` — the Actions runner breaks on the space in "Application Support" (`exit 126`), so the work path must be space-free. One `rm -rf` reaps it all.
- **Per run (fully ephemeral — like a throwaway machine):** each job runs in its own **APFS clone** of the cached agent at `runs/<runner-name>`, and the job's `HOME`, npm cache (`npm_config_cache`), tool cache (`RUNNER_TOOL_CACHE`), `XDG_CACHE_HOME`, and `TMPDIR` are all redirected *inside* that clone. So the checkout, `node_modules`, downloaded actions/tools, dotfiles, and temp files all live in the clone, which is deleted the instant the agent exits. **Nothing touches the user's real `~/.npm` / `~/Library/Caches` / `$TMPDIR`, and nothing survives the job.** Tradeoff: no cross-run cache reuse — deps re-download each run, which is the price of "separate PC every time". (APFS copy-on-write keeps the clone near-instant and almost free on disk.)
- **Signing on the macOS runner (root cause corrected + FIXED 2026-06-03):** the per-run `HOME` redirect breaks code signing because macOS `security` *derives* the user keychain search list from `$HOME` — inside the throwaway clone the login keychain drops out and the list collapses to just the System keychain, so `find-identity -v -p codesigning` returns **0 identities** in the job. electron-builder then falls back to **ad-hoc** even with a correct `CSC_LINK` (its temp CSC keychain can't resolve a valid identity/chain), and notarization rejects the build — on *any* Mac, managed or not. (The earlier fix of merely creating an empty `Library/Preferences` was insufficient: there's usually no `com.apple.security.plist` to persist into — the default list is computed, and computed-without-`$HOME`'s-login-keychain is the bug.) `LocalProcessProvider` now explicitly sets the **job's** user search list to the **host login keychain + System** (`security list-keychains -d user -s …` run with `HOME` pointed at the clone, so the user's real search list is never touched). This restores identity discovery and lets electron-builder's temp `CSC_LINK` keychain chain to the Developer ID intermediate; the temp keychain still owns the signing key (`set-key-partition-list`), so no interactive prompts. **Validated live:** a release leg signed + notarized green on a personal Mac (v0.0.15). Sign by passing the cert through the job **environment** (`CSC_LINK` + `CSC_KEY_PASSWORD`) — the portable pattern that also works on hosted runners.
- **Caveat — the runner Mac must actually *validate* the cert (corporate/MDM Macs may not):** a correct `CSC_LINK` is necessary but not sufficient. On a locked-down, MDM-managed Mac, `security find-identity -v -p codesigning` can return **0** for an otherwise-valid Developer ID cert — notably newer **G2**-issued certs — even though `verify-cert -p codeSign` trusts the chain. (The block is at the *valid-identity* layer: a revocation/OCSP check that can't complete through the corporate network, or an MDM trust override; a self-contained full chain in the keychain doesn't change it.) electron-builder reads `find-identity -v`, finds nothing, and falls back to **ad-hoc** → notarization fails — with a perfectly good secret. The same cert signs fine on an unmanaged Mac or a clean hosted runner. **Diagnose** on the host with `security find-identity -v -p codesigning`: if it shows 0 valid, run signed/notarized release builds on a Mac that validates the cert (an unmanaged personal Mac, or a hosted macOS runner) rather than fighting the corporate trust store. (Found live 2026-06: a corporate work Mac rejected a valid G2 cert that a hosted runner accepted.)
- **Only persistent artifact:** the cached agent template at `~/.mactions/actions-runner` — that's the runner *software* (downloaded once, refreshed on version bumps), not job output. "Remove cached agent" wipes even that.
- **On go-online:** `HostCleanup.sweepOrphans()` deletes any `runs/` leftovers, stray `mactions-*` Windows VM clones (`purgeStrayWindowsClones()`, via the `mactions-fusion-vm` helper's `list`/`delete` verbs, with an on-disk fallback sweep of `~/.mactions/fusion/mactions-*`), and stray Linux containers from a previous crash/force-quit.
- **On go-offline / quit:** `purgeRuns()` sweeps again (defensive).
- **Windows VMs / Linux containers:** throwaway instances are deleted on agent exit and on `stop()`.
- **On demand:** the "Remove cached agent" button (offline) calls `purgeAll()` — removes the cached agent + all run files (not the token). "Sign out" deletes the token file.

The single persistent, intentional cache is the ~200 MB agent template (so restarts are fast); it's documented, reapable from the UI, and never the place jobs actually run.

## Conventions

- **`MactionsCore` has zero external dependencies** and no SwiftUI/AppKit import. Keep it that way — it's what makes the logic testable.
- **Network calls have pure request-builder counterparts** (`jitConfigRequest`, `deviceCodeRequest`, …) so they can be unit-tested without hitting the network. New endpoints should follow that split.
- **`RunnerOrchestrator` is `@MainActor`** and notifies the UI via an `onChange` callback, not Combine — the core stays UI-framework-free.
- **Swift 6** (`swift-tools-version: 6.0`, `swiftLanguageModes: [.v6]` — strict concurrency on), macOS 13+ target. Keep the build warning-clean. Providers are `@unchecked Sendable` (each `NSLock`-guards its own state); `onExit` is `@Sendable`; `RunnerOrchestrator` + its `Slot` + `AppDelegate` are `@MainActor`.
- Runner names are prefixed `mactions-<host>-<rand>` so teardown can identify our own runners and never touch anyone else's.

## Multiple machines

Runners are named `mactions-<host>-<rand>`, and **teardown only deletes runners under *this* machine's prefix** (`machineRunnerPrefix`). So two Macs (personal + work) signed into the same account never clobber each other's runners — even when one is offline.

Crucially, **your repos don't change.** Workflows target **labels** (`runs-on: [self-hosted, macOS, mactions]`), which are identical on every machine; the host only appears in the internal runner *name* (for dedup + scoped teardown), never in anything a workflow references. Keep the label set the same across your Macs and the same `runs-on` works everywhere — GitHub routes each job to whichever machine has a free runner with those labels (and queues if none are online).

## Roadmap

- **Windows follow-ups:** atomic base swaps, concurrent quit-time teardown, automatic GA-major discovery, and per-clone guest credentials are tracked in [WINDOWS.md](docs/WINDOWS.md).
- ~~**Scale-from-zero:** instead of N idle runners, provision on demand~~ — **DONE (2026-06-10, issue #41)**: poll-based (REST queued-jobs detection + ETags; no webhook — a local Mac app has no ingress). See "The loop" above. Possible v2 demand signal: GitHub's official runner **scale-set long-poll client** (`github.com/actions/scaleset`, public preview) for near-instant pickup — verify its routing model (scale sets may replace free-form labels) before adopting.
- **Distribution polish:** signed/notarized release packaging exists; remaining product work is updater hardening, first-run install flow, and an optional Login Item so it can auto-start.
- **Org-level runners** (repo-level today; multi-repo across selected repos is supported).
- **Remaining review items (lower priority):** shorter per-request timeouts + a `gh`-subprocess watchdog (#15); parallel provisioning across repos (#12); runner-tarball checksum verification (#19); draining the agent's stdout/stderr (#16); auto-reclaim of a long-idle cached agent (#17). The token stays a `0600` file by design until the app is signed (#10).

### Hardening already done (from the adversarial review)

Lifecycle is reconcile-based with an `epoch` guard: a failed/late provision can no longer shrink the fleet, phantom an "online" slot, or revive a fleet after the user went offline; a periodic top-up self-heals transient failures (#3,#4,#5,#6,#8,#11). Teardown is per-machine (multi-Mac clobber). `sweepOrphans` now kills orphaned agent processes before purging (#2). The agent template refreshes when GitHub ships a new runner, so runs don't re-pay the self-update (#1). Status no longer re-stamps stale errors (#7); go-online reports the real runner count (#14); the runner download handles any non-2xx (#18).

## Caveats

- A laptop is not an always-on CI host: sleep/lid-close interrupts jobs; nothing runs while the app is closed. That's the intended model ("run my CI while I'm working"), not a 24/7 fleet.
- Running untrusted PR code on a personal self-hosted machine is a real risk: the macOS provider has no process isolation, and the VM-backed Windows/Linux providers remain proof-of-concept security boundaries, so route only trusted/private repositories to Mactions.
