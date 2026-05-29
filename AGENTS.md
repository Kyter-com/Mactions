# AGENTS.md — Mactions

Guide for humans and AI agents working in this repo. Read this before making changes.

## What this is

**Mactions** is a macOS menubar app that turns your Mac into an **on-demand, ephemeral GitHub Actions runner host**. Open the app and it brings self-hosted runners online for a repo; quit it and they go offline. Each runner is single-use (JIT / `--ephemeral`): it registers, runs exactly one job, deregisters, and is replaced while you're online.

Think of it as a laptop-scale, multi-OS, app-controlled version of [actions-runner-controller](https://github.com/actions/actions-runner-controller). The novel part is the UX: "runners exist while the app is open."

### Why it exists

Kyter's `sweep-collector` CI leans on self-hosted runners, and the GitHub-hosted `windows-latest` / `macos-latest` arms have been failing at runner allocation. Mactions is a way to self-host runners for macOS and Linux from a Mac you already have, with a friendly on/off switch.

## Status

Proof-of-concept. Honest accounting:

- ✅ **Core control loop** (auth → JIT config → provider → ephemeral runner → recycle → teardown) is implemented and unit-tested.
- ✅ **Auth, three ways:** one-click **GitHub CLI** reuse (`gh auth token`), device-flow sign-in, or paste-a-PAT. Token stored in a `0600` file (not the keychain — see Auth for why).
- ✅ **Searchable multi-repo picker** (lists repos you can admin) + one ephemeral fleet per selected repo, run concurrently.
- ✅ **Local-process provider**: runs the actions-runner agent directly on the Mac (no VM isolation, but each run is an isolated clone that's wiped on exit — see Host hygiene). This is the runnable MVP path.
- ✅ **SwiftUI menubar app**: status, config, online/offline, live runner list; deregisters on quit.
- 🧪 **Tart provider** (VM isolation): implemented against the `tart` CLI but **experimental** — depends on a prepared base image + SSH bootstrap (see Providers).
- 🧪 **Windows provider** (`WindowsVMProvider`): implemented + unit-tested, but **experimental and not yet live-verified end to end**. **Opt-in only** — OFF by default and gated behind a **"Set up Windows runner"** button; nothing heavy (ISO download, VM build) ever happens automatically. Clones a throwaway Win11-ARM VM per job (Parallels `prlctl` recommended; UTM `utmctl` fallback), SSHes in to launch the win-arm64 runner agent, and destroys the clone on exit. The one-time base image is built by `scripts/prepare-windows-image`, which **auto-downloads the latest Win11 ARM64 ISO** (UUP dump) when you don't supply one, and an **auto-update** check (`WindowsImage`) tells you when a newer Windows build is out. See [Windows support](#windows-support).

## Architecture

Two SwiftPM targets so orchestration logic stays UI-free and testable:

```
MactionsCore (library, pure Foundation)        Mactions (executable, SwiftUI/AppKit)
  GitHubAuth      device flow + PAT + token file   MactionsApp   @main, MenuBarExtra, AppDelegate
  GitHubCLIAuth   reuse `gh auth token`            AppState      glue: one orchestrator per
  GitHubClient    generate-jitconfig/list/delete                 selected repo
  RepoLister      list admin repos (the picker)    MenuContentView  searchable multi-repo picker
  RunnerInstaller downloads the runner agent
  Providers       Local + Tart + factories
  Orchestrator    start/stop/maintain-N
  Cleanup, Shell  host hygiene + process helper
```

**The loop** (`RunnerOrchestrator`):

1. `start()` → for each desired runner, call `GitHubClient.generateJITConfig` (a single-use ephemeral registration).
2. Hand the encoded JIT config to a `RunnerProvider`, which launches the agent (`run.sh --jitconfig …`).
3. The agent registers, runs **one** job, deregisters, exits. The provider's `onExit` fires.
4. While `state == .online`, an exit triggers re-provisioning to keep the fleet at `desiredCount`.
5. `stop()` (or app quit) tears down every provider and best-effort deletes any runner still registered under our `mactions-…` name prefix.

**Lifecycle:** the app is an accessory (menubar-only, no dock icon). `AppDelegate.applicationShouldTerminate` returns `.terminateLater`, runs `goOfflineAndWait()`, then replies — with a 6s hard timeout so a hung network call can't wedge quit. Ephemeral runners + GitHub's offline sweep are the backstop for force-quit/crash.

## Providers

`RunnerProvider` is the substrate one runner executes on.

- **`LocalProcessProvider`** — runs the agent as a child process on the Mac. No isolation. Fine for **trusted private repos**. This is the default and the only one wired into the UI today.
- **`TartProvider`** (experimental) — clones a [Tart](https://tart.run) base image, boots it, SSHes in to launch the agent, deletes the clone on exit. Requires: Apple Silicon, `tart` installed, and a **base image** that already has the actions-runner at `~/actions-runner` plus an SSH login. Image prep is not automated yet. Tart is **macOS/Linux only** — it cannot boot Windows guests, which is why Windows needs its own provider.
- **`WindowsVMProvider`** (experimental) — the Windows analog of `TartProvider`: clones a pristine Win11-ARM base VM, boots it headless, SSHes in to launch the win-arm64 runner agent (`run.cmd --jitconfig …`), and **force-stops + deletes the clone on exit**. Backed by a `WindowsVMCLI` abstraction so it can drive Parallels (`prlctl`, recommended) or UTM (`utmctl`, free fallback). See [Windows support](#windows-support).

### Per-OS reality (important)

- **macOS guests:** Tart via Virtualization.framework. Apple's EULA caps you at **2 concurrent macOS VMs per host**.
- **Linux guests:** easiest. Prefer a container (Colima/Lima/Docker) over a full VM for cleaner ephemerality. On Apple Silicon these are **arm64**; x64 Linux needs slow QEMU emulation, so label runners by arch and adjust workflows.
- **Windows guests:** the hard one, now scaffolded via `WindowsVMProvider` (see [Windows support](#windows-support)). On Apple Silicon only **Windows 11 ARM** runs (Parallels/UTM/QEMU); x64 is emulation-only and slow. Tart doesn't do Windows. The provider clones a throwaway Win11-ARM VM per job and destroys it after — the only way to hit the ephemerality bar on Windows (no APFS-clone HOME-redirect trick exists there).

## Windows support

🧪 **Experimental, and not yet live-verified end to end.** The control-plane code (provider, factory, stray-clone reaping, the image build-id auto-update logic) compiles and is unit-tested; the actual ISO auto-download/convert, the VM boot, + a green Windows job have **not** been run here because that needs a hand-built base image (an ISO download + a multi-minute Windows install) and a hypervisor (neither is present in this dev env). Treat "a Windows job ran on a Mactions runner" as unproven until you complete the image prep and watch one go green.

**Opt-in, button-gated (important).** Windows support is OFF by default. The **"Set up Windows runner"** button in the popover's Windows section is the *only* trigger for any ISO download or base-image build — nothing heavy ever runs automatically. The button: checks a Windows hypervisor CLI is installed (`WindowsVMProviderFactory.detectInstalledCLI()`), checks the ISO-converter deps are present (`WindowsImage.missingConverterDependencies()`), then shells out to `scripts/prepare-windows-image`. Once the base image is built it flips a persisted `windowsImageReady` flag (UserDefaults) and reveals a **Windows toggle** that adds a fleet labeled `[self-hosted, Windows, mactions]` alongside the macOS one on go-online.

**Auto-download-latest + auto-update.** `--iso` is now *optional*: with no ISO, `prepare-windows-image` resolves + downloads the **latest Win11 ARM64 retail build** via UUP dump (the only automatable source), converts it to an ISO, and records the build id at `~/.mactions/windows-base.build`. `WindowsImage` (pure, unit-tested) resolves the latest available build and compares it to that recorded id (`compareBuilds`/`updateAvailable`, numeric dotted-segment ordering so `26100.9 < 26100.10`), so the app can nudge a rebuild when Microsoft ships a newer Windows. The base image is the one cached/auto-refreshed artifact; per-job clones stay throwaway.

### Why Windows is its own provider

Tart cannot boot Windows at all — Windows 11 ARM needs Secure Boot + TPM 2.0, which Apple's Virtualization.framework (Tart's backend) doesn't expose. So `WindowsVMProvider` is a separate provider with a different hypervisor CLI. Only the **orchestration pattern** transfers from `TartProvider`; the VM tool does not.

### How it works (the ephemeral per-job loop)

The provider drives a `WindowsVMCLI` backend (a pure-function abstraction so the command shapes are unit-testable without a VM). Per job:

1. **Clone** a pristine Win11-ARM base VM to a throwaway `mactions-<id>` clone (CoW: `prlctl clone --linked` / `utmctl clone`).
2. **Start** it headless. Key divergence from Tart: these CLIs' `start` returns *immediately* (it does NOT block until the VM powers off, the way `tart run` does).
3. **Poll** the CLI for the guest's IP (longer timeout than Tart — a fresh Win11 clone takes a few minutes to get a DHCP lease).
4. **SSH in** and launch the agent: `run.cmd --jitconfig <BASE64_JIT>`. The base64 JIT string the orchestrator already generates is **OS-agnostic** — the same value that launches `run.sh` on mac/Linux launches `run.cmd` on Windows, so the provider contract needed zero changes. The SSH command **blocks** until `run.cmd`'s single job finishes; that's how we observe completion (since `start` didn't block).
5. **Destroy** on exit: force-stop (`stop --kill`) + `delete` the clone on every path (success, SSH failure, boot failure), then fire `onExit`. `stop()` does the same teardown for the user-went-offline path.

### Ephemerality

A throwaway VM discards the **entire guest disk** per job — npm cache, `%TEMP%`, registry, the `_work` checkout, profile, everything. There is no Windows equivalent of the local provider's APFS-clone HOME-redirect trick, and none is needed: the only thing that persists is the **pristine base image template**; only ephemeral clones are ever booted. `HostCleanup.purgeStrayWindowsClones()` (called from `sweepOrphans()` on go-online) reaps any `mactions-…` clone a crash left behind, so the host accumulates nothing across crashes either. The clone name carries the `mactions-` prefix, so reaping never touches a non-Mactions VM.

### Backends: Parallels vs UTM

- **Parallels (`prlctl`) — recommended.** The only Microsoft-authorized hypervisor for Win11 ARM on Apple Silicon with full HW acceleration, and the only one with a **true background-service headless mode** plus a complete CLI lifecycle that works **without a GUI login session**. Requires Pro/Business Edition (paid) and Full Disk Access for the Parallels app.
- **UTM (`utmctl`) — free fallback.** Works, but `utmctl` uses Apple's ScriptingBridge and **requires an active GUI (Aqua) login session** — it silently fails over SSH or from a pure launchd/headless context. Fine when Mactions runs in the foreground; fragile for an unattended host. Use it only if the Parallels license is a non-starter.
- **QEMU+hvf** is the fully-free, no-GUI-dependency DIY path (you build more plumbing yourself); not implemented here, noted as the next fallback if Parallels cost is rejected.

`WindowsVMProviderFactory.detectInstalledCLI()` picks Parallels if present, else UTM, else `nil`.

### One-time base image prep (the button / the script)

In the app this is the **"Set up Windows runner"** button — the only thing that triggers it. From the CLI:

```bash
# Auto-download the LATEST Win11 ARM64 ISO (UUP dump) + build the base VM:
scripts/prepare-windows-image --name win11-runner-base

# …or supply your own ISO (skips the UUP-dump download/convert):
scripts/prepare-windows-image --iso ~/Downloads/Win11_ARM64.iso --name win11-runner-base
```

`--iso` is **optional**: with none, the script queries UUP dump's JSON API for the latest *retail* Win11 arm64 build and converts the download package to an ISO. That conversion needs a few brew-installable tools — **`aria2c`, `cabextract`, `wimlib`, `chntpw`** — and the script (and `WindowsImage.missingConverterDependencies()`) fails with an exact `brew install …` line if any are missing. The built build id is recorded at `~/.mactions/windows-base.build` for the auto-update check. (Microsoft offers the ISO only as a time-limited interactive download, so a direct URL can't be hard-coded — UUP dump is the automatable path.)

`prepare-windows-image` builds a small unattend ISO from `scripts/autounattend.xml` + `scripts/bootstrap.ps1`, then:

- **Parallels:** creates + boots the VM and drives the install from the CLI; you let `autounattend.xml` + `bootstrap.ps1` finish, detach the install media, and shut it down.
- **UTM:** `utmctl` has **no `create` verb**, so the first template must be built once in the UTM GUI; the script prints the exact steps and the path to the unattend ISO.

`autounattend.xml` lays down a UEFI/GPT Win11 Pro ARM install, creates a throwaway local-admin `runner` with auto-login, skips OOBE, and runs `bootstrap.ps1` on first logon. Its `FirstLogonCommands` **scans every drive root for `\setup\bootstrap.ps1`** (the unattend media's drive letter isn't predictable, and nothing copies the script to `C:\`), so provisioning reliably finds it. `bootstrap.ps1` enables OpenSSH Server, sets the SSH **DefaultShell to `cmd.exe`** (the provider's launch command `cd /d C:\actions-runner && run.cmd …` is CMD syntax — `&&`/`cd /d` are PowerShell 5.1 parse errors, so provider and image are kept in lockstep on cmd), and installs the `actions-runner-win-arm64` agent to `C:\actions-runner` (short root path to dodge Windows MAX_PATH on deep `node_modules` trees). Power the VM off when bootstrap finishes — that powered-off VM is the pristine base; point `WindowsVMProviderFactory(baseImage:)` at its name.

### Workflow change (sweep-collector)

The Windows arm of sweep-collector's `ci.yml` matrix needs its `runner` changed from `windows-latest` to the Mactions Windows label set, mirroring the macOS arm:

```yaml
- os: windows
  runner: [self-hosted, Windows, mactions]   # was: windows-latest
```

The JIT config must carry labels `[self-hosted, Windows, mactions]` for these jobs (configure a Windows fleet with those labels). The existing `cache:` line keys on `runner.environment == 'github-hosted'`, so a self-hosted Windows runner gets no npm cache — same as the macOS arm, and exactly what you want. (This repo doesn't edit sweep-collector; the change is documented here.)

### Perf / compatibility caveats

- sweep-collector's `npm test` is `vitest run` over pure-JS/jsdom unit tests (sql.js is WASM; Playwright/Electron e2e is excluded; `npm ci --ignore-scripts` skips native postinstalls), so it runs on **native arm64 Node 24** with effectively no emulation. Node 24 ships official win-arm64 binaries and `actions/setup-node@v6` reading `.nvmrc` picks them (RUNNER_ARCH=ARM64 on a genuine arm64 runner).
- Emulation is still a *fallback risk* for other workloads: any dependency that pulls an x64-only Windows binary runs under Win11's Prism emulation (slower, occasionally incompatible). Verify a real `npm ci` on win-arm64 before promising parity for anything beyond vitest.
- The win-arm64 runner is still officially "beta"/limited-support; the multi-edition ISO is unactivated (cosmetic nags) — acceptable for a throwaway CI guest, not for production.
- A fresh Win11 clone boots much slower than a Tart Linux guest, so jobs pay a multi-minute clone+boot+SSH tax per run. JIT tokens expire ~60 min after generation; the orchestrator already mints them right before `start()`, so don't pre-warm clones with a stale jitconfig.

## Auth

Friendly by design — no env vars, no hand-copied long tokens.

- **GitHub CLI (easiest):** reuse the token `gh` already holds (`gh auth token`). One click, no setup, nothing to paste — ideal for any dev who has `gh`. `GitHubCLIAuth`.
- **Device flow:** show a short user code, open `github.com/login/device`, poll for approval. Needs a registered **OAuth App client id** (not a secret; device flow has none) — bake one in (or paste it in Settings). This is how homerun gives zero-per-user-setup sign-in once the client id ships.
- **PAT fallback:** paste a token. Works immediately, no OAuth App needed.
- **Scope:** `repo` (classic) or fine-grained **Administration: read & write** on the target repo — required to register/remove repo self-hosted runners.
- **Storage:** a `0600` file at `~/.mactions/auth.token`, cached in memory — **not** the login keychain. An unsigned/dev build has no stable code identity, so the keychain re-prompts on every read, "Always Allow" won't stick, and the modal even steals focus from the popover (cancelling in-flight requests). homerun makes the same file-based choice. A signed/notarized build could move back to the keychain — see Roadmap.

## Build / run / test

```bash
swift build          # compiles MactionsCore + the app
swift test           # 40 unit tests (requests, device-flow guard, repo lister, orchestrator, cleanup, Windows VM command shapes, Windows image build-id/UUP-dump logic)
swift run Mactions   # launches the menubar app for dev (look in the menubar)
```

`swift run` is fine for development; a distributable `.app` bundle (with `LSUIElement`, Developer ID signing, notarization) is a packaging step that doesn't exist yet — see Roadmap.

**CI:** there's deliberately no push-triggered CI. GitHub-hosted `macos-latest` runners aren't available to the Kyter-com org (jobs get no runner and fail in ~4s), and a self-hosted runner only exists while someone has Mactions open — neither is reliable for push CI. So validation is local `swift test` plus the manual **`.github/workflows/selfhosted-smoke.yml`** (`workflow_dispatch`), which builds + tests on a Mactions-provided runner. A dedicated always-on Mac runner would let this become real push CI.

## Host hygiene (no leftover crap)

Ephemeral means the host is left as it was found. This is enforced, not hoped for — see `Cleanup.swift` and `LocalProcessProvider`:

- **Everything Mactions writes lives under one directory:** `~/.mactions/` (the cached agent template + a `runs/` dir + the token). A dot-dir in `$HOME`, **not** `~/Library/Application Support` — the Actions runner breaks on the space in "Application Support" (`exit 126`), so the work path must be space-free. One `rm -rf` reaps it all.
- **Per run (fully ephemeral — like a throwaway machine):** each job runs in its own **APFS clone** of the cached agent at `runs/<runner-name>`, and the job's `HOME`, npm cache (`npm_config_cache`), tool cache (`RUNNER_TOOL_CACHE`), `XDG_CACHE_HOME`, and `TMPDIR` are all redirected *inside* that clone. So the checkout, `node_modules`, downloaded actions/tools, dotfiles, and temp files all live in the clone, which is deleted the instant the agent exits. **Nothing touches the user's real `~/.npm` / `~/Library/Caches` / `$TMPDIR`, and nothing survives the job.** Tradeoff: no cross-run cache reuse — deps re-download each run, which is the price of "separate PC every time". (APFS copy-on-write keeps the clone near-instant and almost free on disk.)
- **Only persistent artifact:** the cached agent template at `~/.mactions/actions-runner` — that's the runner *software* (downloaded once, refreshed on version bumps), not job output. "Remove cached agent" wipes even that.
- **On go-online:** `HostCleanup.sweepOrphans()` deletes any `runs/` leftovers and stray `mactions-*` Tart clones **and Windows VM clones** (`purgeStrayWindowsClones()`, via `prlctl`/`utmctl`) from a previous crash/force-quit.
- **On go-offline / quit:** `purgeRuns()` sweeps again (defensive).
- **Tart / Windows VMs:** clones are deleted on agent exit and on `stop()`.
- **On demand:** the "Remove cached agent" button (offline) calls `purgeAll()` — removes the cached agent + all run files (not the token). "Sign out" deletes the token file.

The single persistent, intentional cache is the ~200 MB agent template (so restarts are fast); it's documented, reapable from the UI, and never the place jobs actually run.

## Conventions

- **`MactionsCore` has zero external dependencies** and no SwiftUI/AppKit import. Keep it that way — it's what makes the logic testable.
- **Network calls have pure request-builder counterparts** (`jitConfigRequest`, `deviceCodeRequest`, …) so they can be unit-tested without hitting the network. New endpoints should follow that split.
- **`RunnerOrchestrator` is `@MainActor`** and notifies the UI via an `onChange` callback, not Combine — the core stays UI-framework-free.
- Swift 5.9 tools, macOS 13+ target. Keep the build warning-clean.
- Runner names are prefixed `mactions-<host>-<rand>` so teardown can identify our own runners and never touch anyone else's.

## Multiple machines

Runners are named `mactions-<host>-<rand>`, and **teardown only deletes runners under *this* machine's prefix** (`machineRunnerPrefix`). So two Macs (personal + work) signed into the same account never clobber each other's runners — even when one is offline.

Crucially, **your repos don't change.** Workflows target **labels** (`runs-on: [self-hosted, macOS, mactions]`), which are identical on every machine; the host only appears in the internal runner *name* (for dedup + scoped teardown), never in anything a workflow references. Keep the label set the same across your Macs and the same `runs-on` works everywhere — GitHub routes each job to whichever machine has a free runner with those labels (and queues if none are online).

## Roadmap

- **Windows** support: scaffolded + wired into the UI (`WindowsVMProvider`, `WindowsImage`, `scripts/prepare-windows-image`, the opt-in "Set up Windows runner" button + Windows toggle — see [Windows support](#windows-support)). Auto-download-latest (UUP dump) and the build-id auto-update check are implemented + unit-tested. **Remaining (NOT live-verified here):** the ISO auto-download/convert actually producing a bootable ISO, a real Win11-ARM base image, the VM boot, and a green Windows job. Also: a backend picker (Parallels vs UTM) in the UI, and a QEMU+hvf backend for a fully-free, no-GUI-session path.
- **Scale-from-zero:** instead of N idle runners, listen for `workflow_job` queued events (webhook or API poll) and provision on demand. This is what ARC does.
- **Distributable `.app`:** Xcode/`xcodebuild` bundle step, `LSUIElement`, Developer ID + notarization, and a Login Item so it can auto-start.
- **Tart image automation:** a `mactions prepare-image` flow that bakes the runner + SSH into a base image.
- **Org-level runners** (repo-level today; multi-repo across selected repos is supported).
- **Tart provider in the UI** + hardening — its background `tart run` thread races the IP wait and the `stop()` path; revisit when Tart graduates from experimental.
- **Remaining review items (lower priority):** shorter per-request timeouts + a `gh`-subprocess watchdog (#15); parallel provisioning across repos (#12); runner-tarball checksum verification (#19); draining the agent's stdout/stderr (#16); auto-reclaim of a long-idle cached agent (#17). The token stays a `0600` file by design until the app is signed (#10).

### Hardening already done (from the adversarial review)

Lifecycle is reconcile-based with an `epoch` guard: a failed/late provision can no longer shrink the fleet, phantom an "online" slot, or revive a fleet after the user went offline; a periodic top-up self-heals transient failures (#3,#4,#5,#6,#8,#11). Teardown is per-machine (multi-Mac clobber). `sweepOrphans` now kills orphaned agent processes before purging (#2). The agent template refreshes when GitHub ships a new runner, so runs don't re-pay the self-update (#1). Status no longer re-stamps stale errors (#7); go-online reports the real runner count (#14); the runner download handles any non-2xx (#18).

## Caveats

- A laptop is not an always-on CI host: sleep/lid-close interrupts jobs; nothing runs while the app is closed. That's the intended model ("run my CI while I'm working"), not a 24/7 fleet.
- Running untrusted PR code on your personal machine is a real risk. The local provider has **no isolation** — use it only for trusted/private repos until the VM provider is production-ready.
