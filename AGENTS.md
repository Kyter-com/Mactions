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
- ✅ **Optional dashboard window** (`DashboardWindowController` — AppKit `NSWindow` hosting SwiftUI, opened from the popover's ⊞ button). A **Pulse-style console** with **Runners / History / Memory** tabs in a master–detail layout:
  - **History** records completed/failed runs (persisted to `~/.mactions/logs/run-history.json`, survives restarts). Selecting a run fetches its **GitHub Actions job log** via the REST API and shows it **inline** (monospaced, line-numbered, searchable) — correlated to the run by the unique `mactions-…` runner name, so it works for **macOS *and* Windows** (logs live on GitHub, sidestepping in-guest capture). Teardown reaps aren't recorded; only runs that finish on their own while online are.
  - **Runners** shows the live fleet; selecting a runner polls its current job's **step checklist** (Jobs API `steps`).
  - **Memory** is a **live** gauge + sparkline + per-bucket RSS (Windows VMs / local runners / app), via `MemorySampler` (Mach `host_statistics64` + `ps`), sampled **only while the window is open**.
  - **Dockless until opened** — showing flips the app to `.regular` (dock icon), closing flips back to `.accessory`; closing the window never quits or takes runners offline. **Liquid Glass** (macOS 26+, `#available`-guarded, material fallback) on the control layer (chips in a `GlassEffectContainer`, search fields, buttons) — never on content, never glass-on-glass.
  - **OS-logo tiles** render from **custom SF Symbol** templates staged as a `.symbolset` (`Sources/Mactions/Media.xcassets`). `swift build` doesn't run `actool`, so `OSLogo` prefers the compiled symbol when present and falls back to drawing the identical `Regular-S` glyph via a tiny SVG-path parser (`SVGSymbol`); it upgrades to true SF Symbols once packaged as a real `.app`.
  - **Performance contract:** all slow work (GitHub fetches, `ps`, VMX reads, log parsing) runs off the main actor (nonisolated async / detached); the views only read published state, so the Mac UI never stutters.
- 🧪 **Tart provider** (VM isolation): implemented against the `tart` CLI but **experimental** — depends on a prepared base image + SSH bootstrap (see Providers).
- 🟢 **Windows provider** (`WindowsVMProvider`): **PROVEN END TO END on VMware Fusion (2026-06-01).** A real ephemeral **Win11-ARM** GitHub Actions runner registered **outbound** to GitHub and ran a **green Windows job** (native `RUNNER_ARCH=ARM64`) on a Mac, then auto-deregistered and the clone powered itself off — host left clean. **VMware Fusion (free)** is the working backend: its `vmrun` CLI does headless clone/start/stop/deleteVM + snapshots, and its EFI boots Win11-ARM — where **stock Homebrew QEMU's firmware hangs** and **UTM is Aqua/SPICE-bound** (both attempted first; see the finding under [Windows support](#windows-support)). Per job: `vmrun clone … linked -snapshot=base-provisioned` a provisioned base, inject a JIT **config disc** (`mactions/jitconfig`), boot → the guest's `MactionsRunOnce` task runs `run.cmd --jitconfig` for ONE job + powers off → the clone is deleted. The Swift **`VMwareCLI`** backend (+ the `scripts/mactions-fusion-vm` lifecycle helper) drives this loop and **"Go online" auto-selects Fusion**; the **one-time base build is now automated end to end** (`scripts/prepare-windows-image` → `scripts/fusion-windows-base`: no-prompt ISO remaster, unattended install, VMware-Tools/vmxnet3, bootstrap, snapshot). **VMware Fusion is the sole backend — QEMU/UTM/Parallels were removed.** The full flow is **proven via the UI** (2026-06-01: the app built the base itself → green `win-smoke` job → clean teardown, host left spotless), and **hardened**: the base build **verifies provisioning before it snapshots** (so a failed install can't false-succeed), a **host-RAM cap** bounds concurrent VMs (no thrashing), build failures land in `~/.mactions/logs`, and "Rebuild / update" force-rebuilds for newer Windows. The repo is now **Swift 6** (strict concurrency). See [Windows support](#windows-support).

## Architecture

Two SwiftPM targets so orchestration logic stays UI-free and testable:

```
MactionsCore (library, pure Foundation)        Mactions (executable, SwiftUI/AppKit)
  GitHubAuth      device flow + PAT + token file   MactionsApp   @main, MenuBarExtra, AppDelegate
  GitHubCLIAuth   reuse `gh auth token`            AppState      glue: one orchestrator per
  GitHubClient    jitconfig/list/delete + actions runs/jobs/logs  selected repo
  RepoLister      list admin repos (the picker)    MenuContentView  searchable multi-repo picker
  RunnerInstaller downloads the runner agent       DashboardWindowController  optional window (dockless until open)
  Providers       Local + Tart + Windows + factories  DashboardView  Pulse-style console: runners / history+inline GH logs / live memory
  Orchestrator    start/stop/maintain-N (+ run-finished events)  OSLogo  custom-SF-Symbol tiles (+ SVGSymbol glyph fallback)
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
- **`WindowsVMProvider`** — the Windows analog of `TartProvider`, but **headless/outbound**: linked-clones a pristine Win11-ARM base VM, injects a per-clone config ISO (copied to the clone's wired `sata0:0` CD), boots it headless so the guest runs `run.cmd --jitconfig …` for one job + self-powers-off, detects completion by polling power state, and **deletes the clone on exit**. Backed by a `WindowsVMCLI` abstraction with **`VMwareCLI`** (VMware Fusion via the `mactions-fusion-vm` helper) as its sole conformer — the proven Win11-ARM backend. `WindowsVMProviderFactory.detectInstalledCLI()` returns it when Fusion (`vmrun`) + the helper are present. See [Windows support](#windows-support).

### Per-OS reality (important)

- **macOS guests:** Tart via Virtualization.framework. Apple's EULA caps you at **2 concurrent macOS VMs per host**.
- **Linux guests:** easiest. Prefer a container (Colima/Lima/Docker) over a full VM for cleaner ephemerality. On Apple Silicon these are **arm64**; x64 Linux needs slow QEMU emulation, so label runners by arch and adjust workflows.
- **Windows guests:** the hard one, handled via `WindowsVMProvider` on **VMware Fusion** (see [Windows support](#windows-support)). On Apple Silicon only **Windows 11 ARM** runs; x64 is emulation-only and slow. Tart doesn't do Windows. The provider linked-clones a throwaway Win11-ARM VM per job and destroys it after — the only way to hit the ephemerality bar on Windows (no APFS-clone HOME-redirect trick exists there).

## Windows support

> ✅ **WORKING BACKEND — VMware Fusion, proven end to end (2026-06-01).** A real ephemeral **Win11-ARM** GitHub Actions runner registered **outbound** to GitHub, ran a **green** Windows job (`RUNNER_OS=Windows`, native `RUNNER_ARCH=ARM64`, user `runner`, Win NT 10.0.26100, `git` present), then **auto-deregistered** and the clone **powered itself off** — host left clean. Recipe below. (Full journey/diagnostics: issue #5, PR #9.)

### Why VMware Fusion — and why not QEMU/UTM

We tried free headless QEMU first; it does **not** boot Win11-ARM on this stack, and UTM is awkward to automate. The decisive findings (full log in issue #5):

- **Stock Homebrew QEMU 11.0.1 + HVF cannot boot Win11-ARM.** The install hangs inside Microsoft's `bootaa64.efi` (CPU busy-spin), reproduced across **both** EDK2 firmwares (Homebrew `edk2-stable202408` and UTM's), `-cpu host`/`max`, and with/without `iommu=smmuv3` — a QEMU-build/HVF incompatibility, not a config knob. The `QEMUCLI` backend + its scripts were **removed** (Fusion is the sole backend).
- **UTM** *does* boot Win11-ARM (it ships its own patched QEMU as non-invocable `.framework` bundles), but it's a poor automation target: `utmctl` is Aqua/ScriptingBridge-bound with **no `create` verb**, the display is SPICE-only (no headless screenshot), its EDK2 misboots a 2nd disc as a hanging "USB HARDDRIVE", and install is a fundamentally **manual** flow (press-any-key + OOBE clicks).
- **VMware Fusion (free since Nov 2024)** has a true headless CLI — `vmrun`, `vmcli`, `vmware-vdiskmanager` under `/Applications/VMware Fusion.app/Contents/Library/` — boots Win11-ARM cleanly, and supports **linked clones + snapshots**. That's the right fit. Tradeoffs: the installer is gated behind the Broadcom portal (Homebrew's cask is disabled), and `vmrun captureScreen` needs guest tools so it can't screenshot pre-install.

### The proven recipe (VMware Fusion)

**One-time base build** → `~/.mactions/fusion/win11-runner-base.vmx`, now **automated end to end** by `scripts/prepare-windows-image` (auto-detects Fusion) → `scripts/fusion-windows-base`. (The original semi-manual flow had 3 manual touches — a boot keypress, VMware Tools install, and an `e1000e`→`vmxnet3` NIC switch — all now automated, as noted inline.) What the automation does:

1. **Build the media.** `prepare-windows-image` downloads the latest Win11-ARM ISO (UUP dump), builds the unattend ISO (`autounattend.xml` + `bootstrap.ps1`), and **remasters a no-prompt Win11 ISO** with xorriso (boots from `efisys_noprompt.bin`, so there's *no* "Press any key to boot from CD" keypress — gracefully falls back to the prompting ISO + one Space-press if xorriso is absent).
2. **Author + boot.** `fusion-windows-base` authors the `.vmx` (`firmware=efi`, 8 GB / 4 vCPU, an NVMe disk via `vmware-vdiskmanager`, and SATA cdroms: the no-prompt Win11 ISO + the unattend ISO + Fusion's bundled VMware-Tools ISO) with the NIC **`vmxnet3` from creation** (no manual switch), then `vmrun start … nogui`. vTPM/SecureBoot are skipped — `autounattend.xml`'s LabConfig bypasses the Win11 hardware checks.
3. **Unattended install.** `autounattend.xml` installs Win11 → creates local-admin `runner`, auto-logs-in, skips OOBE → FirstLogonCommands runs `bootstrap.ps1`.
4. **bootstrap.ps1** (runs at FirstLogon, unattended): first installs **VMware Tools silently** from the attached CD (brings up the `vmxnet3` NIC — no in-box Win11-ARM driver) and waits for network; then installs the win-arm64 actions-runner agent → `C:\actions-runner`, Git (**PortableGit** — full Git *with* `bash`, a 7-Zip self-extractor, no installer GUI), drops `C:\setup\run-job.ps1`, registers the `MactionsRunOnce` logon task, disables UAC, and `shutdown /s`.
5. **Snapshot.** `fusion-windows-base` polls `vmrun list`; when the guest powers off it disconnects the install cdroms and `vmrun snapshot … base-provisioned`. That powered-off snapshot is the pristine base (the linked-clone parent).

**Per-job loop** — fully scriptable, **proven**. Steps 3–6's raw `vmrun` commands are wrapped by **`scripts/mactions-fusion-vm`** (verbs `clone`/`start`/`status`/`stop`/`delete`/`list`/`base-status`), which the Swift `VMwareCLI` backend shells out to. Per-clone state lives in `~/.mactions/fusion/<clone>/` (the base is flat in `~/.mactions/fusion/`); the `clone` verb wires `sata0:0` to `<clone>/config.iso` so the provider's `inject()` is a plain copy:

1. Mint a JIT: `gh api repos/<owner>/<repo>/actions/runners/generate-jitconfig` with `labels:["self-hosted","Windows","mactions"]`, `runner_group_id:1`, `work_folder:"_work"` → `.encoded_jit_config`.
2. Build a config disc: stage `<dir>/mactions/jitconfig` = the encoded JIT (no trailing newline), then `hdiutil makehybrid -iso -joliet -ov -default-volume-name MACTIONS -o cfg.iso <dir>`.
3. `vmrun -T fusion clone <base.vmx> <clone.vmx> linked -snapshot=base-provisioned -cloneName=<name>` (helper: `clone <base> <name>`; ~0.4 s, ~8 MB linked).
4. Point the clone `.vmx`'s `sata0:0.fileName` at `<clone>/config.iso`, `sata0:0.startConnected = "TRUE"` (the helper's `clone` does this; the provider then drops `config.iso` in place).
5. `vmrun -T fusion start <clone.vmx> nogui` → auto-login `runner` → `MactionsRunOnce` → `run-job.ps1` finds the JIT on the config disc → `run.cmd --jitconfig` registers OUTBOUND + runs ONE job → `shutdown /s`.
6. `vmrun -T fusion deleteVM <clone.vmx>` + `rm -rf` the clone dir (helper: `delete <name>`). The runner auto-deregisters (ephemeral JIT).

### Known issues found live — status

- ~~Git for Windows `/VERYSILENT` shows the installer GUI on ARM64~~ — **FIXED**: `bootstrap.ps1` installs Git via **PortableGit** (`PortableGit-*-arm64.7z.exe`, a 7-Zip self-extractor run with `-y` — it auto-confirms and exits, so no installer UI and no stall). This *replaced* MinGit: MinGit dodged the GUI but ships **no `bash`**, so GitHub Actions' `shell: bash` steps (the default for cross-platform `run:`) failed on the runner with `bash: command not found` — which broke a real release. PortableGit is the full Git for Windows (git.exe **and** bash); we add both `\cmd` and `\bin` to the machine PATH.
- **Base-image "needs rebuild" detection (OS build *and* provisioning recipe).** The app surfaces a reason-aware nudge + an offline-gated **Rebuild** button (which drives the live setup stepper) whenever the base is stale, across two dimensions: a newer Win11-ARM **GA build** is out (networked, throttled 6h) and/or the **provisioning recipe** changed (a purely local compare of `~/.mactions/windows-base.recipe` vs `WindowsImage.currentProvisioningRecipeVersion` — instant, surfaced even offline; this is how a `bootstrap.ps1` change like the bash fix reaches an already-built base). A recipe-only rebuild reuses the cached ISO (no ~8 GB re-download). **MAINTAINER TOUCHPOINT** (same spirit as `knownGAMajors`): when a `bootstrap.ps1` change makes a built base stale, bump `PROVISIONING_RECIPE_VERSION` in `prepare-windows-image` AND `WindowsImage.currentProvisioningRecipeVersion` *together* — the unit test `testRecipeVersionConstantMatchesPrepareScript` fails the build if they drift. Bases built before this feature record no recipe file → treated as stale (correct: they predate the PortableGit/bash fix).
- ~~7-Zip URL `7z2408-arm64.msi` is 404~~ — **FIXED**: the ARM64 `.msi` never existed (7-Zip ships ARM64 only as an NSIS `.exe`); `bootstrap.ps1` now uses `7z2601-arm64.exe` + `/S` (pinned — bump manually, no "latest" alias).
- ~~Base build's 3 manual touches (VMware Tools, NIC→vmxnet3, Space-at-boot)~~ — **AUTOMATED**: vmxnet3 is authored into the `.vmx` from creation; `bootstrap.ps1` silently installs VMware Tools from its CD then waits for network; the Win11 ISO is remastered no-prompt with xorriso (`prepare-windows-image` → `make_noprompt_iso`).
- ~~No Swift `VMwareCLI` provider yet~~ — **DONE**: `VMwareCLI` + `scripts/mactions-fusion-vm` land the per-job loop and `detectInstalledCLI`/`detectFreeFirstCLI` return Fusion; `Cleanup.purgeStrayWindowsClones` + `WindowsPreflight` are Fusion-only.
- ~~The one live-verify step (app-driven build + green job)~~ — **DONE (2026-06-01)**: the app built the base end to end (no-prompt ISO booted keyless, OOBE auto-skipped, VMware Tools brought up vmxnet3, bootstrap completed), a `win-smoke` job ran **green** on it via "Go online", and going offline reaped every clone + deregistered every runner. The two live-found build bugs (PCIe bridges, the self-deleting wipe) are fixed (PR #10).

**Hardening (PR #11).** The build now **verifies provisioning before snapshotting** — `bootstrap.ps1` writes a `C:\actions-runner\.mactions-provisioned` sentinel last, and `fusion-windows-base` polls for it via VMware-Tools guest-ops and refuses to snapshot a base that powered off without it (a failed Setup can no longer enshrine a broken base). A pure `WindowsVMBudget` caps concurrent Windows VMs to `(RAM − 6 GB) / 8 GB` so N repos can't thrash the Mac (`AppState.goOnline` skips + explains when over budget). Build transcripts persist to `~/.mactions/logs/` (host) + `C:\setup\logs\` (guest, copied out on timeout). `setUpWindowsRunner(force:)` + a confirm dialog make "Rebuild / update Windows image" actually rebuild for a newer Windows. `sweepOrphans` also runs at launch.

---

> The subsections below are the Fusion implementation detail (opt-in/UI, prerequisites, the per-job loop, base-image prep). **QEMU/UTM/Parallels backends were removed** — only the `WindowsVMCLI` protocol abstraction remains, with `VMwareCLI` (the `mactions-fusion-vm` helper) as its sole conformer.

**Opt-in, button-gated (important).** Windows support is OFF by default. The **"Set up Windows runner"** button in the popover's Windows section is the *only* trigger for any ISO download or base-image build — nothing heavy ever runs automatically. The button: runs `WindowsPreflight.detect()`, **auto-installs the missing FREE brew prerequisites** (the converter tools + xorriso — see below), confirms **VMware Fusion** is installed (it's a manual Broadcom-portal download — the button stops with a hint if it's absent), then shells out to `scripts/prepare-windows-image`. Once the base image is built it flips a persisted `windowsImageReady` flag (UserDefaults) and reveals a **Windows toggle** that adds a fleet labeled `[self-hosted, Windows, mactions]` alongside the macOS one on go-online.

**Prerequisites.** `WindowsPreflight` (pure, Foundation-only, unit-tested) is the prerequisite layer so the user never hand-runs `brew`:

- **Detection** (`detect()` / `makeReport`): probes **Homebrew** (`brew`, on PATH or the `/opt/homebrew`, `/usr/local` prefixes a Finder-launched app won't have on PATH), **VMware Fusion** (`vmrun` inside the app bundle), the **converter tools** (`aria2c`→`aria2`, `cabextract`, `wimlib-imagex`→`wimlib`, `mkisofs`→`cdrtools`, `chntpw`→the `minacle/chntpw` tap — chntpw isn't in homebrew-core), and **xorriso** (the no-prompt-ISO remaster). The `Report` exposes what's installed + missing; `recommendedBackend` is `.vmwareFusion` when present.
- **The install plan** (`installPlan(for:)`) is a **pure, unit-testable function**: one `brew install <missing converter formulae + xorriso>` for the **missing FREE deps only**. It **never** installs a hypervisor — VMware Fusion is a manual Broadcom-portal download, not brew-installable — and if `brew` is absent it returns `.homebrewMissing` with the https://brew.sh hint (it does **not** try to install Homebrew). The actual run (`runInstall`) is a separate call that shells out, so tests don't.
- **UI:** a ✓/✗ checklist (Homebrew, VMware Fusion, converter tools) plus an **"Install free prerequisites"** button (disabled while busy / when not offline). The button installs only the missing free brew deps; "Set up Windows runner" runs the same install automatically before the build. Fusion itself the user installs once from the Broadcom portal.

**Auto-download-latest + auto-update.** `--iso` is now *optional*: with no ISO, `prepare-windows-image` resolves + downloads the **latest Win11 ARM64 GA build** via UUP dump (the only automatable source), converts it to an ISO, and records the build id at `~/.mactions/windows-base.build`. `WindowsImage` (pure, unit-tested) resolves the latest available build and compares it to that recorded id (`compareBuilds`/`updateAvailable`, numeric dotted-segment ordering so `26100.9 < 26100.10`), so the app can nudge a rebuild when Microsoft ships a newer Windows. The base image is the one cached/auto-refreshed artifact; per-job clones stay throwaway.

### Build-path ground truth (audited 2026-05-29; live-verified 2026-06-01)

A full audit against the **live** UUP dump API + converter pinned down several bugs the unit tests had masked (the fixtures encoded shapes the API never sends). All fixed + re-tested:

- **`listid.php` returns `response.builds` as a JSON object** keyed by stringified ints (`"1","2",…`), **not an array.** Swift `parseBuilds` and the script's parser both decoded an array → silent empty result / `'str' object has no attribute 'get'` (the live "Set up Windows runner" crash). Both now walk the dict values.
- **Channel filtering.** The newest rows are usually Insider/canary/preview (`28020`, `29599 rs_prerelease`, "Preview Update", the not-yet-GA 26H1/28000). Selection now keeps only clean GA feature updates (`"Windows 11, version …"`, excluding Insider/preview/cumulative/.NET) on a known-GA major allowlist `{22000,22621,22631,26100,26200}` and picks the highest build **numerically** — today `26200.8524` (25H2). The allowlist is a manual touchpoint (bump when a new HNN GAs); flagged for auto-derivation. Kept in sync between `WindowsImage.selectLatestGA` and the script parser.
- **`get.php` host.** The `autodl=2` convert ZIP is served **only** by `https://uupdump.net`; `api.uupdump.net` returns `400 UNSUPPORTED_COMBINATION`. The script now uses the api host for JSON list endpoints and the www host for the download, with 429 backoff + a ZIP-validity guard.
- **Converter deps:** `aria2c`→`aria2`, `mkisofs`→`cdrtools` (was missing entirely), `chntpw`→`minacle/chntpw` tap (not in core) — all five hard-required by the upstream converter.
- **`autounattend.xml`:** added the Win11 hardware-requirement bypass (TPM/SecureBoot/RAM/CPU/Storage LabConfig keys in windowsPE) — without it Setup halts forever on "This PC can't run Windows 11"; plus a specialize pass that stages `bootstrap.ps1` to `C:\setup\` and a best-effort network-OOBE skip.
- **`bootstrap.ps1`:** resolves the **latest** runner release (no pin), silences the PS 5.1 IWR progress bar (a known large-download throttle), idempotent + size-guarded download with retry, registers the `MactionsRunOnce` logon task (outbound model — no SSH), disables UAC for the disposable admin guest.
- **App glue:** the prep script runs with `/opt/homebrew/bin` on PATH (a Finder-launched app's launchd PATH lacks it, so `command -v` for the converter tools was failing); `windowsImageReady` only flips when a **powered-off base VM is actually verifiable** (`baseImagePoweredOff` → the helper's `base-status` confirms the `base-provisioned` snapshot exists + the VM is off), not on mere script exit 0; failures surface a concise `error:` line, not a raw traceback.

(The remaining live-verify item — a clean app-driven base build + boot — is tracked under [Known issues found live](#known-issues-found-live--status) above. The 25H2 OOBE handoff via `autounattend.xml`'s LocalAccount+AutoLogon+BypassNRO is the main unproven guest-side step.)

### Why Windows is its own provider

Tart cannot boot Windows at all — Windows 11 ARM needs Secure Boot + TPM 2.0, which Apple's Virtualization.framework (Tart's backend) doesn't expose. So `WindowsVMProvider` is a separate provider with a different hypervisor CLI. Only the **orchestration pattern** transfers from `TartProvider`; the VM tool does not.

### How it works (the ephemeral per-job loop)

The provider drives the `VMwareCLI` backend (the `mactions-fusion-vm` helper) via the `WindowsVMCLI` pure-function abstraction, so the command shapes are unit-testable without a VM. The model is **headless + outbound-registration** — no inbound SSH, no guest-IP discovery. Per job:

1. **Clone** a pristine Win11-ARM base VM to a throwaway `mactions-<id>` clone — `mactions-fusion-vm clone` does `vmrun … clone … linked -snapshot=base-provisioned` and wires the clone's `sata0:0` CD to `<clone-dir>/config.iso`.
2. **Build** a tiny per-clone **config ISO** (`hdiutil makehybrid -iso -joliet`, via `WindowsImage.configISOArgs`) carrying the base64 JIT at `mactions/jitconfig`. The JIT is OS-agnostic — the same value that launches `run.sh` on mac/Linux drives `run.cmd` on Windows.
3. **Inject** it into the powered-off clone: a plain byte copy to `<clone-dir>/config.iso` (the wired CD). No attach command, no in-bundle dance.
4. **Start** headless (`vmrun start … nogui`). The base image's in-guest run-once Scheduled Task (`MactionsRunOnce` → `run-job.ps1`) finds the JIT on the config disc, runs `run.cmd --jitconfig` for ONE job (registering **outbound** to GitHub, auto-deregistering after), then `shutdown /s`.
5. **Detect completion by power state**: a background thread polls `status` (the helper reads `vmrun list`) — first confirming the clone reached `.running` (the `phase()` classifier defeats the just-cloned `stopped` false positive), then waiting for the guest's self power-off. The host never reads the job's exit code (GitHub is the authoritative result); `onExit(0)` on a clean power-off, `onExit(1)` on boot/job timeout.
6. **Destroy** on every path: `delete` the clone (`vmrun stop hard` + `deleteVM` + `rm -rf`) and remove the per-clone config scratch, then fire `onExit`. `stop()` does the same teardown for the user-went-offline path. The `tornDown` guard fires `onExit` exactly once.

### Ephemerality

A throwaway VM discards the **entire guest disk** per job — npm cache, `%TEMP%`, registry, the `_work` checkout, profile, everything. There is no Windows equivalent of the local provider's APFS-clone HOME-redirect trick, and none is needed: the only thing that persists is the **pristine base image** (`~/.mactions/fusion/win11-runner-base.vmx` + its `base-provisioned` snapshot); only ephemeral linked clones are ever booted. `HostCleanup.purgeStrayWindowsClones()` (called from `sweepOrphans()` on go-online) reaps any `mactions-…` clone (subdir under `~/.mactions/fusion/`) a crash left behind, so the host accumulates nothing across crashes either. The clone name carries the `mactions-` prefix, so reaping never touches the base or a non-Mactions VM.

### One-time base image prep (the button / the script)

In the app this is the **"Set up Windows runner"** button — the only thing that triggers it. From the CLI (VMware Fusion must be installed — a free, manual Broadcom-portal download):

```bash
# Auto-download the LATEST Win11 ARM64 ISO (UUP dump) + build the base VM:
scripts/prepare-windows-image --name win11-runner-base

# …or supply your own ISO (skips the UUP-dump download/convert):
scripts/prepare-windows-image --iso ~/Downloads/Win11_ARM64.iso --name win11-runner-base
```

`--iso` is **optional**: with none, the script queries UUP dump's JSON API for the latest *stable GA* Win11 arm64 build (the newest rows are Insider/preview, so it filters to GA) and converts the download package to an ISO. That conversion needs five brew-installable tools, **all hard-required by the upstream `convert.sh`** — **`aria2` (aria2c), `cabextract`, `wimlib` (wimlib-imagex), `cdrtools` (mkisofs), `chntpw`** (the last via the `minacle/chntpw` tap; not in homebrew-core) — plus **`xorriso`** for the no-prompt boot ISO; the script fails with an exact `brew install …` line if a converter is missing (xorriso is optional — it falls back to a one-keypress prompting ISO). The built build id is recorded at `~/.mactions/windows-base.build` for the auto-update check. (Microsoft offers the ISO only as a time-limited interactive download, so a direct URL can't be hard-coded — UUP dump is the automatable path.)

`prepare-windows-image` then builds the unattend ISO (`scripts/autounattend.xml` + `scripts/bootstrap.ps1`), remasters a no-prompt Win11 ISO (`make_noprompt_iso`), and hands off to **`scripts/fusion-windows-base`** for the fully-automated headless build (author `.vmx` with a vmxnet3 NIC → `vmrun start nogui` → autounattend installs → `bootstrap.ps1` installs VMware Tools + the runner agent → `shutdown /s` → snapshot `base-provisioned`).

`autounattend.xml` lays down a UEFI/GPT Win11 Pro ARM install, creates a throwaway local-admin `runner` with auto-login, skips OOBE, and runs `bootstrap.ps1` on first logon. Its `FirstLogonCommands` **scans every drive root for `\setup\bootstrap.ps1`** (the unattend media's drive letter isn't predictable), so provisioning reliably finds it. `bootstrap.ps1` (BUILD-time, once) installs VMware Tools (for the vmxnet3 NIC), then the latest `actions-runner-win-arm64` agent to `C:\actions-runner` (short root path to dodge Windows MAX_PATH on deep `node_modules` trees) + Git (PortableGit — full Git + `bash`) + 7-Zip, drops `C:\setup\run-job.ps1` (the PER-CLONE runtime), registers a recurring **logon Scheduled Task** (`MactionsRunOnce`) that runs it on every boot, and disables UAC for the disposable guest. On a clone boot, `run-job.ps1` finds the JIT on the injected config disc (volume `MACTIONS` / drive scan), runs `run.cmd --jitconfig` for ONE job, then powers the VM off — no inbound SSH. The powered-off, snapshotted VM is the pristine base; `WindowsVMProviderFactory(baseImage:)` points at its name.

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
swift test           # 60 unit tests (requests, device-flow guard, repo lister, orchestrator, cleanup, Windows VM command shapes, Windows image build-id/UUP-dump logic, Windows preflight detection + free-first brew-command builder)
swift run Mactions   # launches the menubar app for dev (look in the menubar)
```

`swift run` is fine for development; a distributable `.app` bundle (with `LSUIElement`, Developer ID signing, notarization) is a packaging step that doesn't exist yet — see Roadmap.

**CI:** there's deliberately no push-triggered CI. GitHub-hosted `macos-latest` runners aren't available to the Kyter-com org (jobs get no runner and fail in ~4s), and a self-hosted runner only exists while someone has Mactions open — neither is reliable for push CI. So validation is local `swift test` plus the manual **`.github/workflows/selfhosted-smoke.yml`** (`workflow_dispatch`), which builds + tests on a Mactions-provided runner. A dedicated always-on Mac runner would let this become real push CI.

## Host hygiene (no leftover crap)

Ephemeral means the host is left as it was found. This is enforced, not hoped for — see `Cleanup.swift` and `LocalProcessProvider`:

- **Everything Mactions writes lives under one directory:** `~/.mactions/` (the cached agent template + a `runs/` dir + the token). A dot-dir in `$HOME`, **not** `~/Library/Application Support` — the Actions runner breaks on the space in "Application Support" (`exit 126`), so the work path must be space-free. One `rm -rf` reaps it all.
- **Per run (fully ephemeral — like a throwaway machine):** each job runs in its own **APFS clone** of the cached agent at `runs/<runner-name>`, and the job's `HOME`, npm cache (`npm_config_cache`), tool cache (`RUNNER_TOOL_CACHE`), `XDG_CACHE_HOME`, and `TMPDIR` are all redirected *inside* that clone. So the checkout, `node_modules`, downloaded actions/tools, dotfiles, and temp files all live in the clone, which is deleted the instant the agent exits. **Nothing touches the user's real `~/.npm` / `~/Library/Caches` / `$TMPDIR`, and nothing survives the job.** Tradeoff: no cross-run cache reuse — deps re-download each run, which is the price of "separate PC every time". (APFS copy-on-write keeps the clone near-instant and almost free on disk.)
- **Signing on the macOS runner:** the per-run `HOME` is redirected into the throwaway clone, and macOS `security` keeps its keychain search list in `$HOME/Library/Preferences/com.apple.security.plist`. So `LocalProcessProvider` seeds the clone's `_home` with `Library/Preferences` — without it, `security list-keychains -s` silently no-ops (rc=0, nothing persists), the search list collapses to empty inside the job, and code signing falls back to an **ad-hoc** signature that fails notarization (even though the same secret signs cleanly on a normal `HOME`, e.g. a GitHub-hosted runner). With that seeded, sign by passing the cert through the job **environment** — e.g. electron-builder's `CSC_LINK` (base64 Developer ID Application `.p12`) + `CSC_KEY_PASSWORD`, which imports into its own temp keychain; this is the portable pattern that also works on hosted runners. Host-keychain **auto-discovery** (electron-builder with `CSC_LINK` unset) still won't work — the redirected `HOME`'s search list doesn't include the user login keychain by design; making it would be a config opt-in, not the default. Use `CSC_LINK`.
- **Caveat — the runner Mac must actually *validate* the cert (corporate/MDM Macs may not):** a correct `CSC_LINK` is necessary but not sufficient. On a locked-down, MDM-managed Mac, `security find-identity -v -p codesigning` can return **0** for an otherwise-valid Developer ID cert — notably newer **G2**-issued certs — even though `verify-cert -p codeSign` trusts the chain. (The block is at the *valid-identity* layer: a revocation/OCSP check that can't complete through the corporate network, or an MDM trust override; a self-contained full chain in the keychain doesn't change it.) electron-builder reads `find-identity -v`, finds nothing, and falls back to **ad-hoc** → notarization fails — with a perfectly good secret. The same cert signs fine on an unmanaged Mac or a clean hosted runner. **Diagnose** on the host with `security find-identity -v -p codesigning`: if it shows 0 valid, run signed/notarized release builds on a Mac that validates the cert (an unmanaged personal Mac, or a hosted macOS runner) rather than fighting the corporate trust store. (Found live 2026-06: a corporate work Mac rejected a valid G2 cert that a hosted runner accepted.)
- **Only persistent artifact:** the cached agent template at `~/.mactions/actions-runner` — that's the runner *software* (downloaded once, refreshed on version bumps), not job output. "Remove cached agent" wipes even that.
- **On go-online:** `HostCleanup.sweepOrphans()` deletes any `runs/` leftovers and stray `mactions-*` Tart clones **and Windows VM clones** (`purgeStrayWindowsClones()`, via the `mactions-fusion-vm` helper's `list`/`delete` verbs, with an on-disk fallback sweep of `~/.mactions/fusion/mactions-*`) from a previous crash/force-quit.
- **On go-offline / quit:** `purgeRuns()` sweeps again (defensive).
- **Tart / Windows VMs:** clones are deleted on agent exit and on `stop()`.
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

- **Windows** support: VMware Fusion backend — **proven end to end via the UI** (automated base build → green job → clean teardown) + hardened (see [Windows support](#windows-support)). Deferred Windows follow-ups: **atomic rebuild** (build to a temp VM + swap, so a failed update can't lose the working base — today `fusion-windows-base` wipes-then-rebuilds); **concurrent teardown on quit** (would need `RunnerOrchestrator` as an `actor` under Swift 6 — the launch-sweep + GitHub's ephemeral deregister self-heal leaks meanwhile); **GA `knownGAMajors` auto-derivation** (no false-positive-free GA signal from UUP dump, so it stays a documented manual touchpoint, kept in sync between `WindowsImage` + `prepare-windows-image`); **hung-guest watchdog** (already bounded by `bootTimeout` + `jobTimeout`); **per-clone guest password** (accepted: the guest is outbound-only + destroyed per job).
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
