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
- 🟢 **Windows provider** (`WindowsVMProvider`): **PROVEN END TO END on VMware Fusion (2026-06-01).** A real ephemeral **Win11-ARM** GitHub Actions runner registered **outbound** to GitHub and ran a **green Windows job** (native `RUNNER_ARCH=ARM64`) on a Mac, then auto-deregistered and the clone powered itself off — host left clean. **VMware Fusion (free)** is the working backend: its `vmrun` CLI does headless clone/start/stop/deleteVM + snapshots, and its EFI boots Win11-ARM — where **stock Homebrew QEMU's firmware hangs** and **UTM is Aqua/SPICE-bound** (both attempted first; see the finding under [Windows support](#windows-support)). Per job: `vmrun clone … linked -snapshot=base-provisioned` a provisioned base, inject a JIT **config disc** (`mactions/jitconfig`), boot → the guest's `MactionsRunOnce` task runs `run.cmd --jitconfig` for ONE job + powers off → the clone is deleted. The **one-time base build is currently semi-manual** on Fusion (VMware Tools + a NIC switch to `vmxnet3` + one Space-press at boot — see the recipe under [Windows support](#windows-support)); the **per-job loop is fully scriptable**. The earlier `QEMUCLI`/UTM `WindowsVMCLI` scaffolding remains in the tree but does **not** boot Win11-ARM on this macOS/QEMU stack; a Swift `VMwareCLI` provider is the next step (Roadmap). See [Windows support](#windows-support).

## Architecture

Two SwiftPM targets so orchestration logic stays UI-free and testable:

```
MactionsCore (library, pure Foundation)        Mactions (executable, SwiftUI/AppKit)
  GitHubAuth      device flow + PAT + token file   MactionsApp   @main, MenuBarExtra, AppDelegate
  GitHubCLIAuth   reuse `gh auth token`            AppState      glue: one orchestrator per
  GitHubClient    generate-jitconfig/list/delete                 selected repo
  RepoLister      list admin repos (the picker)    MenuContentView  searchable multi-repo picker
  RunnerInstaller downloads the runner agent
  Providers       Local + Tart + Windows + factories
  Orchestrator    start/stop/maintain-N
  WindowsPreflight free-first prereq detect + brew installer (pure plan)
  WindowsImage    UUP-dump latest-ISO resolve + build-id auto-update
  Cleanup, Shell  host hygiene + process helper

  WindowsVMCLI impls (free-first):
    QEMUCLI       fully-headless QEMU + swtpm + edk2 (driven by helper script)
    UTMCLI        free, but `utmctl` needs an Aqua login session
    ParallelsCLI  paid, only honored if already installed
scripts/                                       (driven by AppState + provider)
  prepare-windows-image     UUP-dump → ISO + autounattend ISO + FAT image
  qemu-windows-base         headless Win11-ARM install via QEMU (new)
  mactions-qemu-vm          per-clone QEMU+swtpm lifecycle (clone/start/stop/...)
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
- **`WindowsVMProvider`** (experimental) — the Windows analog of `TartProvider`, but **headless/outbound**: clones a pristine Win11-ARM base VM, injects a per-clone config ISO (Parallels attaches it; UTM overwrites a fixed in-bundle disk), boots it headless so the guest runs `run.cmd --jitconfig …` for one job + self-powers-off, detects completion by polling power state, and **force-stops + deletes the clone on exit**. Backed by a `WindowsVMCLI` abstraction so it can drive UTM (`utmctl`, **free/OSS — the app's default**) or Parallels (`prlctl`, only if already present). The interactive app picks the backend **free-first** via `WindowsVMProviderFactory.detectFreeFirstCLI()` (UTM, else an existing Parallels); `detectInstalledCLI()` is the older robustness-first order kept for reference. See [Windows support](#windows-support).

### Per-OS reality (important)

- **macOS guests:** Tart via Virtualization.framework. Apple's EULA caps you at **2 concurrent macOS VMs per host**.
- **Linux guests:** easiest. Prefer a container (Colima/Lima/Docker) over a full VM for cleaner ephemerality. On Apple Silicon these are **arm64**; x64 Linux needs slow QEMU emulation, so label runners by arch and adjust workflows.
- **Windows guests:** the hard one, now scaffolded via `WindowsVMProvider` (see [Windows support](#windows-support)). On Apple Silicon only **Windows 11 ARM** runs (Parallels/UTM/QEMU); x64 is emulation-only and slow. Tart doesn't do Windows. The provider clones a throwaway Win11-ARM VM per job and destroys it after — the only way to hit the ephemerality bar on Windows (no APFS-clone HOME-redirect trick exists there).

## Windows support

> ✅ **WORKING BACKEND — VMware Fusion, proven end to end (2026-06-01).** A real ephemeral **Win11-ARM** GitHub Actions runner registered **outbound** to GitHub, ran a **green** Windows job (`RUNNER_OS=Windows`, native `RUNNER_ARCH=ARM64`, user `runner`, Win NT 10.0.26100, `git` present), then **auto-deregistered** and the clone **powered itself off** — host left clean. Recipe below. (Full journey/diagnostics: issue #5, PR #9.)

### Why VMware Fusion — and why not QEMU/UTM

We tried free headless QEMU first; it does **not** boot Win11-ARM on this stack, and UTM is awkward to automate. The decisive findings (full log in issue #5):

- **Stock Homebrew QEMU 11.0.1 + HVF cannot boot Win11-ARM.** The install hangs inside Microsoft's `bootaa64.efi` (CPU busy-spin), reproduced across **both** EDK2 firmwares (Homebrew `edk2-stable202408` and UTM's), `-cpu host`/`max`, and with/without `iommu=smmuv3` — a QEMU-build/HVF incompatibility, not a config knob. The `QEMUCLI` backend + `scripts/qemu-windows-base`/`mactions-qemu-vm` remain in the tree but are **non-functional for Win11-ARM** here.
- **UTM** *does* boot Win11-ARM (it ships its own patched QEMU as non-invocable `.framework` bundles), but it's a poor automation target: `utmctl` is Aqua/ScriptingBridge-bound with **no `create` verb**, the display is SPICE-only (no headless screenshot), its EDK2 misboots a 2nd disc as a hanging "USB HARDDRIVE", and install is a fundamentally **manual** flow (press-any-key + OOBE clicks).
- **VMware Fusion (free since Nov 2024)** has a true headless CLI — `vmrun`, `vmcli`, `vmware-vdiskmanager` under `/Applications/VMware Fusion.app/Contents/Library/` — boots Win11-ARM cleanly, and supports **linked clones + snapshots**. That's the right fit. Tradeoffs: the installer is gated behind the Broadcom portal (Homebrew's cask is disabled), and `vmrun captureScreen` needs guest tools so it can't screenshot pre-install.

### The proven recipe (VMware Fusion)

**One-time base build** → `~/.mactions/fusion/win11-runner-base.vmx`. Currently **semi-manual** (3 touches flagged below); a Swift provider + a no-prompt ISO would automate them:

1. `vmcli VM Create -n win11-runner-base -d ~/.mactions/fusion -g arm-windows11-64`, then author the `.vmx`: `firmware=efi`, 8 GB / 4 vCPU, an NVMe disk (`vmware-vdiskmanager -c -s 64GB -a lsilogic -t 0`), and two SATA cdroms — the Win11 ISO (`~/.mactions/win11-base.iso`) + `~/.mactions/mactions-unattend.iso` (ISO9660 with `autounattend.xml` at root, `hdiutil makehybrid -ov -iso -joliet -default-volume-name UNATTEND`). vTPM/SecureBoot are skipped — `autounattend.xml`'s LabConfig bypasses the Win11 hardware checks.
2. `vmrun -T fusion start … gui` and **press Space once** at "Press any key to boot from CD" *(manual touch #1 — Microsoft `cdboot`, hypervisor-independent; a no-prompt ISO would remove it)*. `autounattend.xml` then installs unattended → creates local-admin `runner`, auto-logs-in, skips OOBE.
3. **Install VMware Tools** *(manual touch #2)* — Virtual Machine → Install VMware Tools → run setup in the guest. Provides the `vmxnet3` network driver + clipboard.
4. Power off; switch the NIC `e1000e`→`vmxnet3` in the `.vmx` *(manual touch #3 — `e1000e` has no Win11-ARM inbox driver)*, reconnect, boot → network up (`curl github.com` = 200).
5. Run `bootstrap.ps1` **elevated** (Register-ScheduledTask needs admin): installs the win-arm64 actions-runner agent → `C:\actions-runner`, drops `C:\setup\run-job.ps1`, registers the `MactionsRunOnce` logon task, disables UAC. Verify: `Test-Path C:\actions-runner\run.cmd` = True, `C:\setup\run-job.ps1` = True, `MactionsRunOnce` task = Ready.
6. Shut down (`vmrun stop … soft`) + `vmrun snapshot … base-provisioned`. That powered-off snapshot is the pristine base.

**Per-job loop** — fully scriptable, **proven**:

1. Mint a JIT: `gh api repos/<owner>/<repo>/actions/runners/generate-jitconfig` with `labels:["self-hosted","Windows","mactions"]`, `runner_group_id:1`, `work_folder:"_work"` → `.encoded_jit_config`.
2. Build a config disc: stage `<dir>/mactions/jitconfig` = the encoded JIT (no trailing newline), then `hdiutil makehybrid -iso -joliet -ov -default-volume-name MACTIONS -o cfg.iso <dir>`.
3. `vmrun -T fusion clone <base.vmx> <clone.vmx> linked -snapshot=base-provisioned -cloneName=<name>`.
4. Edit the clone `.vmx`: point `sata0:0.fileName` at `cfg.iso`, set `sata0:0.startConnected = "TRUE"`.
5. `vmrun -T fusion start <clone.vmx> nogui` → auto-login `runner` → `MactionsRunOnce` → `run-job.ps1` finds the JIT on the config disc → `run.cmd --jitconfig` registers OUTBOUND + runs ONE job → `shutdown /s`.
6. `vmrun -T fusion deleteVM <clone.vmx>` + `rm -rf` the clone dir. The runner auto-deregisters (ephemeral JIT).

### Known issues found live (fix before productionizing)

- **Git for Windows `/VERYSILENT` still shows the installer GUI on ARM64** — fine with a human present, but **breaks the unattended FirstLogonCommands path**. Needs different silent flags (or winget / a manual extract).
- **7-Zip URL `7z2408-arm64.msi` is 404** (stale) — optional/non-fatal (`bootstrap.ps1` continues); resolve the current version.
- **Base build's 3 manual touches** (VMware Tools, NIC→vmxnet3, Space-at-boot) — a no-prompt ISO + a VMware-Tools install stage would make it hands-free.
- **No Swift `VMwareCLI` provider yet** — the per-job loop is proven in shell but not wired into the app's "Go online" (next step — Roadmap).

---

> ℹ️ **The subsections below document the earlier QEMU/UTM (`WindowsVMProvider`/`QEMUCLI`/`UTMCLI`) design.** They're **superseded** by the VMware Fusion recipe above for the working path, but kept for reference (the scaffolding is still in the tree, the prereq/preflight UI still targets it, and a Swift `VMwareCLI` provider will replace it).

🧪 **The QEMU/UTM control-plane code** (provider, factory, stray-clone reaping, image build-id auto-update) compiles and is unit-tested, but the QEMU backend does not boot Win11-ARM here (see the finding above).

**Opt-in, button-gated (important).** Windows support is OFF by default. The **"Set up Windows runner"** button in the popover's Windows section is the *only* trigger for any ISO download or base-image build — nothing heavy ever runs automatically. The button: runs `WindowsPreflight.detect()`, **auto-installs the missing FREE prerequisites** (UTM + the converter tools, via Homebrew — see below), confirms a hypervisor CLI is now installed, then shells out to `scripts/prepare-windows-image`. Once the base image is built it flips a persisted `windowsImageReady` flag (UserDefaults) and reveals a **Windows toggle** that adds a fleet labeled `[self-hosted, Windows, mactions]` alongside the macOS one on go-online.

**Free-first prerequisites (installed by the app, not by hand).** `WindowsPreflight` (pure, Foundation-only, unit-tested) is the prerequisite layer so the user never hand-runs `brew`:

- **Detection** (`detect()` / `makeReport`): probes **Homebrew** (`brew`, on PATH or the `/opt/homebrew`, `/usr/local` prefixes a Finder-launched app won't have on PATH), the **hypervisor backends** (UTM's bundled `utmctl`, Parallels' `prlctl`, QEMU's `qemu-system-aarch64`), and the **converter tools** (`aria2c`→`aria2`, `cabextract`, `wimlib-imagex`→`wimlib`, `mkisofs`→`cdrtools`, `chntpw`→the `minacle/chntpw` tap — chntpw isn't in homebrew-core). The `Report` exposes what's installed, what's missing, and a `recommendedBackend` chosen **free-first**: UTM (free) if present, else an *existing* Parallels (paid — never recommended for install), else QEMU.
- **The install plan** (`installPlan(for:)`) is a **pure, unit-testable function**: it builds `brew install --cask utm` (only when no hypervisor is present yet) + one `brew install <missing converter formulae>` for the **missing FREE deps only**. It **never** emits `--cask parallels` (paid), and if `brew` is absent it returns `.homebrewMissing` with the https://brew.sh hint — it does **not** try to install Homebrew. The actual run (`runInstall`) is a separate call that shells out, so tests don't.
- **UI:** a ✓/✗ checklist (Homebrew, hypervisor, converter tools) plus an **"Install free prerequisites"** button (disabled while busy / when not offline). The button installs only the missing free deps; "Set up Windows runner" runs the same install automatically before the build.
- **UTM caveat** (carried over): `utmctl` uses Apple's ScriptingBridge and needs an active GUI/login session — fine for this interactive foreground app, fragile for an unattended launchd host. That's why Parallels is the more robust choice *if you already own it*, but we never push the user to buy it.

**Auto-download-latest + auto-update.** `--iso` is now *optional*: with no ISO, `prepare-windows-image` resolves + downloads the **latest Win11 ARM64 GA build** via UUP dump (the only automatable source), converts it to an ISO, and records the build id at `~/.mactions/windows-base.build`. `WindowsImage` (pure, unit-tested) resolves the latest available build and compares it to that recorded id (`compareBuilds`/`updateAvailable`, numeric dotted-segment ordering so `26100.9 < 26100.10`), so the app can nudge a rebuild when Microsoft ships a newer Windows. The base image is the one cached/auto-refreshed artifact; per-job clones stay throwaway.

### Build-path ground truth + what still needs a live run (audited 2026-05-29)

A full audit against the **live** UUP dump API + converter pinned down several bugs the unit tests had masked (the fixtures encoded shapes the API never sends). All fixed + re-tested:

- **`listid.php` returns `response.builds` as a JSON object** keyed by stringified ints (`"1","2",…`), **not an array.** Swift `parseBuilds` and the script's parser both decoded an array → silent empty result / `'str' object has no attribute 'get'` (the live "Set up Windows runner" crash). Both now walk the dict values.
- **Channel filtering.** The newest rows are usually Insider/canary/preview (`28020`, `29599 rs_prerelease`, "Preview Update", the not-yet-GA 26H1/28000). Selection now keeps only clean GA feature updates (`"Windows 11, version …"`, excluding Insider/preview/cumulative/.NET) on a known-GA major allowlist `{22000,22621,22631,26100,26200}` and picks the highest build **numerically** — today `26200.8524` (25H2). The allowlist is a manual touchpoint (bump when a new HNN GAs); flagged for auto-derivation. Kept in sync between `WindowsImage.selectLatestGA` and the script parser.
- **`get.php` host.** The `autodl=2` convert ZIP is served **only** by `https://uupdump.net`; `api.uupdump.net` returns `400 UNSUPPORTED_COMBINATION`. The script now uses the api host for JSON list endpoints and the www host for the download, with 429 backoff + a ZIP-validity guard.
- **Converter deps:** `aria2c`→`aria2`, `mkisofs`→`cdrtools` (was missing entirely), `chntpw`→`minacle/chntpw` tap (not in core) — all five hard-required by the upstream converter.
- **`autounattend.xml`:** added the Win11 hardware-requirement bypass (TPM/SecureBoot/RAM/CPU/Storage LabConfig keys in windowsPE) — without it Setup halts forever on "This PC can't run Windows 11"; plus a specialize pass that stages `bootstrap.ps1` to `C:\setup\` and a best-effort network-OOBE skip.
- **`bootstrap.ps1`:** resolves the **latest** runner release (no pin), silences the PS 5.1 IWR progress bar (a known large-download throttle), idempotent + size-guarded download with retry, forces SSH password auth + restarts sshd after writing config, disables UAC for the disposable admin guest.
- **App glue:** the prep script runs with `/opt/homebrew/bin` on PATH (a Finder-launched app's launchd PATH lacks it, so `command -v` for the converter tools was failing); `windowsImageReady` only flips when a **powered-off base VM is actually verifiable** (`baseImagePoweredOff`), not on mere script exit 0 (the UTM path only prints manual steps); failures surface a concise `error:` line, not a raw traceback.

**Still NOT live-verified — needs a real multi-GB build + boot:**

- **Headless UTM IP discovery (the crux).** `utmctl ip-address` reports a lease only via the QEMU guest agent, which has no first-class arm64-Windows build (UTM #5134), so on a bare guest the IP poll times out. Durable fix = host-side DHCP-lease discovery by the clone's MAC (MAC-capture plumbing not yet built), or a config-ISO/JIT-injection approach that avoids inbound SSH entirely. The provider now fails fast with an actionable message instead of a silent stall. Note **UTM also can't create a VM headlessly** (no `create` verb — first template is a one-time GUI build); only Parallels does the whole thing from the CLI.
- **25H2 OOBE handoff** — the ConX setup path may still drop into interactive OOBE; LocalAccount+AutoLogon should avoid it but it's unproven on a real 26200 boot.
- **SSH password login + cmd DefaultShell + `run.cmd` blocking for one job + the admin/UAC token model** — all need one live job to confirm end to end.

### Why Windows is its own provider

Tart cannot boot Windows at all — Windows 11 ARM needs Secure Boot + TPM 2.0, which Apple's Virtualization.framework (Tart's backend) doesn't expose. So `WindowsVMProvider` is a separate provider with a different hypervisor CLI. Only the **orchestration pattern** transfers from `TartProvider`; the VM tool does not.

### How it works (the ephemeral per-job loop)

The provider drives a `WindowsVMCLI` backend (a pure-function abstraction so the command shapes are unit-testable without a VM). The model is **headless + outbound-registration** — no inbound SSH, no guest-IP discovery (the qemu-guest-agent that `utmctl ip-address` needs has no arm64-Windows build). Per job:

1. **Clone** a pristine Win11-ARM base VM to a throwaway `mactions-<id>` clone (`prlctl clone --linked` / `utmctl clone`).
2. **Build** a tiny per-clone **config ISO** (`hdiutil makehybrid -iso -joliet`, via `WindowsImage.configISOArgs`) carrying the base64 JIT at `mactions/jitconfig`. The JIT is OS-agnostic — the same value that launches `run.sh` on mac/Linux drives `run.cmd` on Windows.
3. **Inject** it into the powered-off clone (`WindowsInjectionPlan`): Parallels **attaches** it as a CD (`prlctl set <clone> --device-set cdrom0 --image <iso> --connect`); UTM has no attach verb, so the provider **overwrites a fixed in-bundle data disk** in the clone bundle (`<clone>.utm/Data/<image>`). *(The UTM overwrite is UNVERIFIED — see the live-verification checklist below.)*
4. **Start** headless. The base image's in-guest run-once Scheduled Task (`bootstrap.ps1`) finds the JIT on the config disc, runs `run.cmd --jitconfig` for ONE job (registering **outbound** to GitHub, auto-deregistering after), then `shutdown /s`.
5. **Detect completion by power state**: a background thread polls `status` — first confirming the clone reached `.running` (the `phase()` classifier defeats the just-cloned `stopped` false positive), then waiting for the guest's self power-off. The host never reads the job's exit code (GitHub is the authoritative result); `onExit(0)` on a clean power-off, `onExit(1)` on boot/job timeout.
6. **Destroy** on every path: force-stop + `delete` the clone (and remove the per-clone config scratch), then fire `onExit`. `stop()` does the same teardown for the user-went-offline path. The `tornDown` guard fires `onExit` exactly once.

### Ephemerality

A throwaway VM discards the **entire guest disk** per job — npm cache, `%TEMP%`, registry, the `_work` checkout, profile, everything. There is no Windows equivalent of the local provider's APFS-clone HOME-redirect trick, and none is needed: the only thing that persists is the **pristine base image template**; only ephemeral clones are ever booted. `HostCleanup.purgeStrayWindowsClones()` (called from `sweepOrphans()` on go-online) reaps any `mactions-…` clone a crash left behind, so the host accumulates nothing across crashes either. The clone name carries the `mactions-` prefix, so reaping never touches a non-Mactions VM.

### Backends: QEMU vs UTM vs Parallels (free-first)

The app is **free/OSS-first**, and the new default is the headless **QEMU + swtpm + edk2** stack. UTM remains as a runtime option (free but needs a GUI session); Parallels is honored if you already have it, never recommended for purchase.

- **QEMU + swtpm + edk2 (`QEMUCLI`) — free, fully headless, the default.** Drives a `qemu-system-aarch64` VM directly via the `scripts/mactions-qemu-vm` helper. No Aqua login session required — runs from launchd, an SSH session, anywhere. swtpm is the software TPM 2.0 emulator (Win11 hard-requires TPM); edk2 ARM64 firmware ships with Homebrew's `qemu` formula. Per-clone JIT delivery is a real `-cdrom` attach (cleaner than UTM's in-bundle-overwrite hack). `WindowsPreflight` installs the stack with `brew install qemu swtpm`. The base-image build is fully automated by `scripts/qemu-windows-base` (see [Win11-ARM QEMU boot quirks](#win11-arm-qemu-boot-quirks)).
- **UTM (`utmctl`) — free, but Aqua-bound.** Open-source (QEMU backend). Caveat: `utmctl` uses Apple's ScriptingBridge and **requires an active GUI login session** — silently fails over SSH or from a pure launchd context. Honored when present (`detectFreeFirstCLI()` falls back to it after QEMU). Base-image build needs a one-time GUI wizard (no `utmctl create` verb).
- **Parallels (`prlctl`) — paid, only if already installed.** The only Microsoft-authorized hypervisor for Win11 ARM with full HW acceleration + a complete headless CLI. We **never** install it (it's paid); the free-first picker uses it only when it's the sole backend present.

Pickers: `WindowsVMProviderFactory.detectFreeFirstCLI()` (QEMU → UTM → Parallels) is the default; `detectInstalledCLI()` follows the same order. The QEMU backend's "installed" condition is BOTH the `mactions-qemu-vm` helper being present alongside the binary AND `qemu-system-aarch64` on disk.

### Win11-ARM QEMU boot quirks

Booting the UUP-dump Win11 ARM ISO under stock Homebrew QEMU needs five non-obvious knobs — figured out the hard way (debugged 2026-05-31, see issue #5 for the full investigation log). All five are baked into `scripts/qemu-windows-base`.

**Install-time vs clone-boot — they must agree on the machine.** Knobs 2–4 (the keypress sprayer, single boot CD, USB-flash unattend) are *install-only*: a per-job clone boots the already-installed OS from disk, so there's no boot CD, no unattend media, and no "Press any key" prompt. But the **machine-defining flags must be identical** between the install (`qemu-windows-base`) and every clone boot (`mactions-qemu-vm start`), because Windows binds its HAL + ACPI device stack to the virtual hardware it was installed on — booting a clone on a different machine model/CPU/firmware can bugcheck (INACCESSIBLE_BOOT_DEVICE / ACPI_BIOS_ERROR). So the clone mirrors the base on `-cpu host`, `-M virt,gic-version=max,acpi=on,iommu=smmuv3` (the `iommu` adds the ACPI IORT table Windows enumerated at install — the substantive one), the edk2 code/vars pflash pairing, the OS-disk `bootindex=1`, and the NIC `romfile=` OPROM suppression. The config CD gets `bootindex=99` so EDK2 reaches the Windows Boot Manager NVRAM entry (carried in the copied `efi_vars.fd`) deterministically. The clone keeps `-serial null` (no keypress watchdog needed once installed).

1. **`-M virt,iommu=smmuv3`** — without SMMU exposure, EDK2's console redirector stays silent past device enumeration and the boot loader's prompt never reaches the serial sink (which we tail for the auto-keypress watchdog, below).
2. **Auto-keypress sprayer** — Microsoft's `cdboot.efi` prints "Press any key to boot from CD or DVD......" and times out in ~5 s. We daemonize QEMU then spam Enter via QMP `send-key` at 4 Hz for 30 s, guaranteeing the prompt is satisfied even with cache-cold paths.
3. **Single boot CD on virtio-scsi** — two `scsi-cd` devices on the same `virtio-scsi-pci` controller deadlocks `cdboot.efi` (it stops printing the prompt entirely). The Win11 ISO stays on virtio-scsi; the unattend payload moves to a USB flash image.
4. **Unattend on USB flash with `bootindex=99`** — a FAT-formatted image attached as `usb-storage,removable=on,bootindex=99` (NOT a CD) on the xhci bus. The high bootindex deprioritizes it in EDK2's boot-order enumeration; with a low bootindex EDK2 tried to PXE/USB-boot from it and broke cdboot in the same way two CDs did. Windows Setup scans removable USB media for `autounattend.xml`, so functionality is identical.
5. **`virtio-net-pci,romfile=`** — the iPXE option ROM that ships with virtio-net causes EDK2 to attempt PXE boot during BdsDxe and never fall through to cdboot. Disabling the OPROM with `romfile=` fixes it cleanly.

Other details for the QEMU base build:
- **Homebrew edk2 firmware** (`/opt/homebrew/share/qemu/edk2-aarch64-code.fd` + `edk2-arm-vars.fd`) is the right pair. UTM's bundled EDK2 firmware redirects Microsoft's text-mode output to the framebuffer ONLY, not to serial — so our watchdog can't see "Press any key".
- **`-cpu host`** (HVF passthrough) works; `-cpu max` works too. The `pauth-impdef=on` property is version-dependent and missing in QEMU 11.0.1 from Homebrew — relying on defaults.
- **`bootstrap.ps1` ends with `shutdown /s /t 30`** so the headless install path can detect "install complete" purely from guest power-off (no need to scrape logs). Harmless on UTM/Parallels (user previously did this by hand).
- **The base image lives at `~/.mactions/windows-base/`** as a directory: `base.qcow2` + `efi_vars.fd` + `tpm-state/`. Per-job clones overlay these into `~/.mactions/windows-clones/<id>/`.

### One-time base image prep (the button / the script)

In the app this is the **"Set up Windows runner"** button — the only thing that triggers it. From the CLI:

```bash
# Auto-download the LATEST Win11 ARM64 ISO (UUP dump) + build the base VM:
scripts/prepare-windows-image --name win11-runner-base

# …or supply your own ISO (skips the UUP-dump download/convert):
scripts/prepare-windows-image --iso ~/Downloads/Win11_ARM64.iso --name win11-runner-base
```

`--iso` is **optional**: with none, the script queries UUP dump's JSON API for the latest *stable GA* Win11 arm64 build (see the ground-truth note below — the newest rows are Insider/preview, so it filters to GA) and converts the download package to an ISO. That conversion needs five brew-installable tools, **all hard-required by the upstream `convert.sh`** — **`aria2` (aria2c), `cabextract`, `wimlib` (wimlib-imagex), `cdrtools` (mkisofs), `chntpw`** (the last via the `minacle/chntpw` tap; not in homebrew-core) — and the script (and `WindowsImage.missingConverterDependencies()`) fails with an exact `brew install …` line if any are missing. The built build id is recorded at `~/.mactions/windows-base.build` for the auto-update check. (Microsoft offers the ISO only as a time-limited interactive download, so a direct URL can't be hard-coded — UUP dump is the automatable path.)

`prepare-windows-image` builds a small unattend ISO from `scripts/autounattend.xml` + `scripts/bootstrap.ps1`, then:

- **Parallels:** creates + boots the VM and drives the install from the CLI; you let `autounattend.xml` + `bootstrap.ps1` finish, detach the install media, and shut it down.
- **UTM:** `utmctl` has **no `create` verb**, so the first template must be built once in the UTM GUI; the script prints the exact steps and the path to the unattend ISO.

`autounattend.xml` lays down a UEFI/GPT Win11 Pro ARM install, creates a throwaway local-admin `runner` with auto-login, skips OOBE, and runs `bootstrap.ps1` on first logon. Its `FirstLogonCommands` **scans every drive root for `\setup\bootstrap.ps1`** (the unattend media's drive letter isn't predictable), so provisioning reliably finds it. `bootstrap.ps1` (BUILD-time, once) installs the latest `actions-runner-win-arm64` agent to `C:\actions-runner` (short root path to dodge Windows MAX_PATH on deep `node_modules` trees), drops `C:\setup\run-job.ps1` (the PER-CLONE runtime), registers a recurring **logon Scheduled Task** (`MactionsRunOnce`) that runs it on every boot, and disables UAC for the disposable guest. On a clone boot, `run-job.ps1` finds the JIT on the injected config disc (volume `MACTIONS` / drive scan), runs `run.cmd --jitconfig` for ONE job, then powers the VM off — no inbound SSH. Power the base VM off when bootstrap finishes — that powered-off VM is the pristine base; point `WindowsVMProviderFactory(baseImage:)` at its name.

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
- **Only persistent artifact:** the cached agent template at `~/.mactions/actions-runner` — that's the runner *software* (downloaded once, refreshed on version bumps), not job output. "Remove cached agent" wipes even that.
- **On go-online:** `HostCleanup.sweepOrphans()` deletes any `runs/` leftovers and stray `mactions-*` Tart clones **and Windows VM clones** (`purgeStrayWindowsClones()`, via `prlctl`/`utmctl` **and the QEMU `mactions-qemu-vm` helper's `list`/`delete` verbs**, with an on-disk fallback sweep of `~/.mactions/windows-clones/mactions-*` that also `pkill`s any leaked detached `qemu`/`swtpm`) from a previous crash/force-quit.
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

- **Windows** support: scaffolded + wired into the UI (`WindowsVMProvider`, `WindowsImage`, `WindowsPreflight`, `scripts/prepare-windows-image`, the opt-in "Set up Windows runner" button + the free-first preflight checklist/"Install free prerequisites" button + Windows toggle — see [Windows support](#windows-support)). Free-first prerequisite detection + the brew-command builder, auto-download-latest (UUP dump), and the build-id auto-update check are implemented + unit-tested. **Remaining (NOT live-verified here):** the actual `brew install` of the free deps, the ISO auto-download/convert producing a bootable ISO, a real Win11-ARM base image, the VM boot, and a green Windows job. Also: a QEMU+hvf backend wired to a `WindowsVMCLI` for a fully-free, no-GUI-session path (preflight already detects QEMU), and an explicit backend picker in the UI.
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
