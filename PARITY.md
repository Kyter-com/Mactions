# Runner Parity — Mactions vs GitHub-hosted

This is the honest, per-OS contract for anyone pointing an existing workflow at
a Mactions runner: what matches GitHub-hosted behavior, what deliberately
differs, and what to do about each difference. It is the companion to
[BASE.md](BASE.md) (the philosophy: bake in runner/OS *semantics*, leave
*convenience tools* to the workflow) and the working résumé of the
[issue #37](https://github.com/Kyter-com/Mactions/issues/37) parity audit —
every claim below was verified against the official images, GitHub docs, or
adversarially fact-checked research (2026-06).

Compared against: GitHub-hosted `windows-11-arm` (image `20260525.56.1`),
`macos-latest`/`macos-26` (arm64), and `ubuntu-24.04-arm` — public-repo tier.

---

## Targeting a Mactions runner (`runs-on`)

Mactions runners register with fixed label sets:

| OS | `runs-on` |
|---|---|
| macOS | `[self-hosted, macOS, mactions]` (editable per repo in the app) |
| Windows | `[self-hosted, Windows, mactions]` |
| Linux | `[self-hosted, Linux, ARM64, mactions]` |

A hosted-style `runs-on: windows-11-arm` / `macos-latest` / `ubuntu-latest`
**never routes to a Mactions runner** — the job queues for the hosted pool (and
a job that matches *no* runner fails after 24 h queued). Registering a
self-hosted runner *with* a hosted label name would not help: verified against
GitHub's docs and community reports, on github.com jobs using hosted runner
names are routed to the **hosted** pool regardless of identically-labeled
self-hosted runners (behavior GitHub changed silently ~May 2025 and documents
nowhere — treat it as unsupported). The supported move is the explicit label
rewrite above, which is also GitHub's own recommendation ("begin with
`self-hosted`").

The Linux `ARM64` label is deliberate: `ubuntu-latest` is x64, a Mactions
container is genuinely arm64, so workflows must opt in rather than mis-target
prebuilt-x64 jobs.

## Semantics that flip on ANY self-hosted runner

- **`runner.environment`** is `self-hosted` (hosted: `github-hosted`). Steps
  gated `if: runner.environment == 'github-hosted'` silently skip; the inverse
  branches start running. Audit your conditionals when migrating.
- **`RUNNER_NAME`** is `mactions-<host>-<6hex>` (hosted: "Hosted Agent").
- **Job duration**: the workflow-level `timeout-minutes` default (360) applies
  everywhere. GitHub allows self-hosted jobs up to 5 days via an explicit
  `timeout-minutes`, but the Mactions **Windows** host watchdog reclaims a VM
  ~6.5 h after boot (GitHub's 6-h allowance + lifecycle headroom) — so
  `timeout-minutes` > 360 is not yet supported on the Windows fleet. macOS and
  Linux runners have no provider-level timeout. (The watchdog exists for wedged
  guests; GitHub's own cancellation is the real enforcer.)
- **`ACTIONS_RUNNER_HOOK_JOB_STARTED/COMPLETED`** are not configured (hosted
  doesn't have them either — they're a self-hosted-only feature Mactions could
  add: a `.env` file in the runner directory; `.ps1` on Windows, `.sh` on
  macOS/Linux; verified to work with JIT runners). Ask if you need them.
- **Concurrency** is host-bounded, not plan-bounded: Windows VMs are capped by
  host RAM (`(GB − 6) / 8` → one VM on a 16 GB Mac), Linux containers by
  `(GB − 4) / 6` and `cores / 2`. A 10-shard matrix runs mostly serially.

## Runner identity / env contract (all three OSes — at parity)

`RUNNER_OS` / `RUNNER_ARCH` / all standard `GITHUB_*` contexts behave
identically to hosted. `ImageOS` is baked/derived per OS (`win25` on Windows —
the closest whitelist-safe token, since GitHub publishes no Win11/ARM token;
`macos<major>` live-derived on macOS; `ubuntu24` already in the official Linux
image), and `RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` are set hosted-shaped on
all three. **`ImageVersion` is intentionally unset** everywhere: it is an
author-chosen cache-key fragment, not a runner contract — nothing fails when
it's absent, and faking a hosted build id would advertise a tool-cache layer
the minimal base doesn't carry. Cache keys embedding `$ImageVersion` get an
empty segment and never match hosted-produced caches.

## Tools: the BASE.md line

The base ships only the practical runner contract: **runner agent, Git
(+ bash, + Git LFS 3.7.1 — same version as hosted), PowerShell 7 on Windows**,
plus hypervisor plumbing. Everything else is the workflow's job:

- `setup-node` / `setup-python` / `setup-go` / `setup-dotnet` / `setup-java` /
  etc. all work — but the tool cache is **cold every job** (the clone/container
  is destroyed per job), so they download instead of hitting
  `hostedtoolcache` (~10–60 s vs ~1 s hosted). `actions/cache` works normally
  (network-backed).
- **Not present, install in the workflow if needed** (hosted has these;
  Mactions deliberately doesn't): `gh`, `jq`, `yq`, OpenSSL, CMake, Ninja,
  LLVM/gcc, Bazel, Chocolatey/NuGet/Helm/pipx, browsers + webdrivers
  (`CHROMEWEBDRIVER` etc. are unset), MySQL/Apache/Nginx, PowerShell modules
  (Pester, Az, …), Visual Studio / MSVC / Windows SDKs / vcpkg
  (`VCPKG_INSTALLATION_ROOT` unset — native MSVC builds are out of scope),
  Mercurial, Stack. There is no `choco` to bootstrap with on Windows — use
  direct downloads or `Invoke-WebRequest` + silent installers.
- **7-Zip** (removed in Windows recipe v12): hosted ships `7z` on PATH; the
  Mactions base doesn't carry it (it failed every prong of the BASE.md decision
  test, and the old install was silently unreliable). If a step needs it:

  ```yaml
  - name: Install 7-Zip
    shell: pwsh
    run: |
      Invoke-WebRequest https://www.7-zip.org/a/7z2601-arm64.exe -OutFile $env:TEMP\7z.exe
      Start-Process $env:TEMP\7z.exe -ArgumentList '/S' -Wait
      Add-Content $env:GITHUB_PATH "$env:ProgramFiles\7-Zip"
  ```

  pwsh's `Expand-Archive`/`Compress-Archive` and the tar/unzip in Git's
  `usr\bin` (reachable inside `shell: bash` steps) cover most archive needs
  without it.
- **zstd** is absent on hosted Win11-ARM *and* Mactions (`actions/cache` falls
  back to gzip; with `enableCrossOsArchive: true` a zstd Linux-saved cache is a
  hard miss on Windows — same on both).

---

## Windows (`WindowsVMProvider`, Win11-ARM on VMware Fusion)

### Hardware / sizing

| | Hosted `windows-11-arm` (public) | Mactions |
|---|---|---|
| CPU | 4 vCPU (Cobalt 100, SVE2) | 4 vCPU (Apple Silicon via Fusion, no SVE2) |
| RAM | 16 GB | **8 GB** (private-tier hosted is 2 vCPU / 8 GB) |
| Disk | 256 GB C: (docs headline "14 GB free") | **64 GB** C:, growable sparse |

Knobs: `scripts/prepare-windows-image --ram MB --disk GB` at base-build time
(CLI only; the app builds with defaults). The host VM budget reads the base
VMX's actual `memsize`, so a 16 GB base correctly halves how many VMs run
concurrently — `--ram` is fully supported, it just trades concurrency.
SVE2-detecting code paths take the NEON fallback (slower, not a crash);
benchmarks are noisier under host contention.

### OS / config — at parity (recipe-stamped, sentinel-verified)

Execution policy (LocalMachine Unrestricted, v5) · `LongPathsEnabled=1` (v6) ·
Git post-install: system `safe.directory "*"`, `GCM_INTERACTIVE=Never`, seeded
`ssh_known_hosts` (v7) · Windows Update + telemetry disabled by policy (v8) ·
Defender scan/monitoring disabled + `C:\`/`D:\` exclusions with the official
Win11-ARM `DisableBlockAtFirstSeen` exception (v9–v10) · `ImageOS`/toolcache
env (v11) · 7-Zip removed (v12) · **Git at the hosted `C:\Program Files\Git`
layout** with the full hosted machine-PATH composition — `\cmd`, the mingw
`\bin` (clangarm64 on ARM64), `\usr\bin`, and `\bin` (what hosted's
`PathOption=CmdTools` + `Add-MachinePathItem` produce) — **hosted-exact UAC**
(`ConsentPromptBehaviorAdmin=0`, UAC on — the runner task's `-RunLevel
Highest` supplies the full admin token), and **UTC time zone** (v13). The
installer still differs (PortableGit SFX vs Inno — the ARM64 Inno installer
can show GUI and stall an unattended build), but the resulting layout, PATH,
config, and env match: hardcoded `C:\Program Files\Git\…` paths resolve, and
MSYS coreutils (`sed`/`awk`/`grep`) resolve from pwsh/cmd steps via `usr\bin`,
just like hosted (appended, so System32's `find`/`sort` still win on both).

### Differences that remain (accepted, documented)

- **Windows 11 Pro, unactivated** vs Enterprise, activated. Cosmetic nags;
  Enterprise-only features absent; low CI impact.
- **OS build is newer** than hosted (UUP-dump latest GA, cumulative over
  hosted's patch level) — a difference in your favor.
- **Interactive desktop session** (autologon `runner`) vs hosted's headless
  `runneradmin`: GUI/window-focus tests that fail on hosted can pass here; a
  hardcoded `C:\Users\runneradmin` breaks (home is `C:\Users\runner`).
- **Symlinks work without Developer Mode** — the runner task's elevated token
  carries `SeCreateSymbolicLinkPrivilege`, so `core.symlinks=true` checkouts
  that fail on hosted (whose agent runs with a filtered token,
  runner-images#14084) succeed here.
- **Python**: no `py` launcher and no pre-baked interpreters. `setup-python`
  installs native arm64; hosted-workaround scripts (`py -3.13`, branching on
  the emulated-x64 `AMD64` arch report) misbehave; conversely x64-only wheels
  lose hosted's emulated-x64 escape hatch.
- **x64 emulation rule of thumb** (same as hosted Prism, found live): x64
  *binaries* emulate fine, but npm packages with platform-keyed native binaries
  need a win32-arm64 build or another matrix leg (e.g. `wrangler`/workerd), and
  mixed-mode .NET tooling under emulation needs the matching x64 .NET runtime
  installed (the Azure Trusted Signing fix — see AGENTS.md).
- **Same-on-both, no action**: Docker/Windows containers/`services:` (GitHub
  doesn't support them on any Windows runner), WSL 1+2, nested virt, zstd.
- **pwsh tracks latest** (hosted pins 7.4.x); runner agent self-updates in-job
  if the baked one is stale (seconds).
- **tmate-style debugging** would connect (outbound tunnel) but the session is
  bounded by the one-job lifecycle + watchdog, and tmate's win-arm64 binary is
  unverified.

### Base lifecycle (Mactions-only concept)

A **missing** base blocks the Windows fleet (jobs queue unclaimed until built);
a **stale** base (newer Windows GA, or a provisioning-recipe bump like v12)
still runs jobs fine — staleness only surfaces the rebuild nudge in the app.
Recipe-only rebuilds reuse the cached ISO.

---

## macOS (`LocalProcessProvider`, bare host)

Runs on the actual Mac — there is no VM and no image, so "parity" is mostly
about the per-run isolation Mactions adds:

- **Spec comparison works in your favor**: hosted `macos-latest`/`macos-26` is
  3 vCPU (M1) / 7 GB / 14 GB SSD; your Mac is almost certainly faster.
- **Tools = whatever the host Mac has** plus `setup-*`. Hosted's Xcode
  multi-install / Homebrew package set is not replicated — BASE.md scope.
- **Per-run HOME isolation**: each job runs in a throwaway APFS clone with
  HOME, npm/tool caches, and TMPDIR redirected inside it. One consequence is
  baked into the provider: login-keychain code signing collapses without the
  real `$HOME`, so the provider seeds the per-run keychain search list, and
  release signing should pass certs via `CSC_LINK`/`CSC_KEY_PASSWORD` env (the
  pattern that also works hosted). MDM-managed Macs can still refuse a valid
  identity at the host level — check `security find-identity -v -p codesigning`.
- **`ImageOS`** is derived live from the host (`macos26` on Tahoe), and
  `GCM_INTERACTIVE=Never` is set per job so a host-configured Git Credential
  Manager can't hang a headless job.
- Apple's EULA caps macOS **VMs** at 2 per host — moot for the bare-host
  provider, relevant only to the experimental Tart path.

---

## Linux (`LinuxContainerProvider`, official `actions-runner` container)

Closest to hosted of the three — it *is* GitHub's runner image
(`ghcr.io/actions/actions-runner`, Ubuntu 24.04 base):

- **arm64, always** (`--platform linux/arm64`, no silent amd64 emulation).
  `ubuntu-latest` workflows must opt in via the `ARM64` label and use
  arm64-capable deps; push x64 legs to hosted via a matrix.
- **Spec**: hosted `ubuntu-24.04-arm` public is 4 vCPU / 16 GB; a Mactions
  container is capped at `--cpus 2 --memory 6g`.
- **Image is minimal by upstream design**: the runtime-deps base has no
  Node/Python/Go/gcc — even more minimal than hosted's Ubuntu image.
  `setup-*` covers it (proven live: `setup-go` on the first green job).
- **`jobs.<id>.container`, `services:`, docker-in-workflow are unsupported**
  (no Docker socket in the job). Hosted Linux *does* support these — the one
  Linux capability gap; a trusted-repo opt-in is deferred.
- **Isolation**: shares the host kernel (Apple `container` gives a lightweight
  VM per container). Trusted/private repos only — same guidance GitHub gives
  for all self-hosted runners.

---

## Maintainer notes

- Windows parity changes ride `PROVISIONING_RECIPE_VERSION` (currently **13**)
  — bump `scripts/prepare-windows-image` and
  `WindowsImage.currentProvisioningRecipeVersion` together (a unit test
  enforces it), and keep `bootstrap.ps1` pure ASCII with its UTF-8 BOM.
- The reverted **package picker** (PR #35, commit `6e627d5`) remains the
  blessed path if tool-stack parity (toolcache warming, `gh`, CMake, JDKs,
  jq/yq) ever becomes worth its weight — revert the revert (#36) rather than
  reinventing it, and keep it opt-in per BASE.md.
- Upstream references: the hosted image readmes + `toolset-win-11-arm64.json`
  and the `Configure-*.ps1` scripts in
  [actions/runner-images](https://github.com/actions/runner-images), and the
  verified limits/routing/hooks research in issue #37.
