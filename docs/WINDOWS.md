# Windows Runner — VMware Fusion

This document holds the Windows-specific architecture, build recipe, historical
findings, and downstream compatibility notes that would otherwise overwhelm
[AGENTS.md](../AGENTS.md); the user-visible compatibility contract remains
[PARITY.md](PARITY.md), and [BASE.md](BASE.md) defines what belongs in the runner
environment.

Repository state in this document was reconciled on 2026-07-31 against Windows
provisioning recipe **v14**.

## Current contract

- VMware Fusion is the sole Windows backend; QEMU, UTM, and Parallels backends
  are not shipped.
- Windows setup is opt-in and button-gated, so no ISO download or base build
  starts until the user chooses **Set up Windows runner**.
- The one-time base is a powered-off Win11-ARM VM at
  `~/.mactions/fusion/win11-runner-base.vmx` with a `base-provisioned` snapshot.
- Each job runs in a linked clone, registers outbound with a one-job JIT config,
  records a verified infrastructure outcome, powers off, and is deleted.
- Windows jobs target `[self-hosted, Windows, mactions]`; hosted labels such as
  `windows-11-arm` do not route to Mactions.

The full app-driven path was proven end to end on 2026-06-01: the app built the
base, a native ARM64 runner completed a green Windows job, and teardown removed
the runner and clone.

## Per-job lifecycle

1. `RunnerOrchestrator` mints a JIT config for a unique `mactions-…` runner.
2. `WindowsVMProvider` creates a linked clone from `base-provisioned`.
3. The host builds a tiny config ISO containing `mactions/jitconfig` and also
   retries delivery through VMware Tools to `C:\setup\jitconfig`.
4. Auto-login starts the elevated `MactionsRunOnce` task, whose `run-job.ps1`
   finds either JIT channel and invokes `run.cmd --jitconfig` for one job.
5. The guest writes `C:\setup\logs\run-outcome.txt` as `success`, `no-jit`, or
   `runner-exit:N`, keeps Tools alive briefly for capture, and powers off.
6. The host accepts exit 0 only with a verified success outcome, preserves the
   guest transcript on infrastructure failure, and deletes the clone.

GitHub remains authoritative for the workflow conclusion; the guest outcome is
the provider's infrastructure signal.

## One-time base build

`scripts/prepare-windows-image` resolves or accepts a Win11-ARM ISO, remasters it
for no-prompt boot, builds the unattend media, and delegates the Fusion build to
`scripts/fusion-windows-base`.

The automated build:

1. Resolves the latest known GA Win11-ARM build through UUP dump unless `--iso`
   supplies an existing image.
2. Authors a 4-vCPU, 8-GB, 64-GB Fusion VM with NVMe storage, `vmxnet3`, the
   no-prompt Windows ISO, unattend media, and VMware Tools media.
3. Installs Windows 11 Pro ARM unattended, creates local administrator `runner`,
   auto-logs in, and starts `bootstrap.ps1`.
4. Installs VMware Tools, the latest ARM64 Actions runner, PortableGit with bash
   and Git LFS, the newest LTS PowerShell 7, the run-once task, and the narrow
   hosted-semantic settings documented in PARITY.md.
5. Writes `.mactions-provisioned` only after required tools and settings verify,
   powers off, disconnects install media, and snapshots `base-provisioned`. A
   failed check or an error nothing handles writes its reason to
   `C:\setup\logs\bootstrap-failed.txt` instead and powers off a minute later;
   the host reads it while VMware Tools still answer, fails the build with that
   reason, and restores the previous base.

Typical direct use is:

```bash
# Resolve the latest GA media and build the base.
scripts/prepare-windows-image

# Reuse an existing ISO.
scripts/prepare-windows-image --iso /path/to/Win11_Arm64.iso
```

The app normally drives this flow and installs only the missing Homebrew
converter prerequisites; VMware Fusion itself remains a manual install.

### Maintainer invariants

- Keep `PROVISIONING_RECIPE_VERSION` in `scripts/prepare-windows-image` equal to
  `WindowsImage.currentProvisioningRecipeVersion`; a unit test enforces this.
- Bump the recipe whenever a guest-side provisioning change makes an existing
  base stale.
- Keep every guest-side PowerShell file pure ASCII with a UTF-8 BOM because
  Windows PowerShell 5.1 decodes BOM-less files as ANSI.
- Write the provisioning sentinel last and never snapshot a base that has not
  passed its guest verification checks.
- Preserve the v14 rule that guest power-off without a success outcome is an
  infrastructure failure.
- Fail the guest bootstrap through `Stop-BootstrapWithFailure`, never a bare
  `shutdown`, so the host can show the reason.
- A failed rebuild always restores the previous base. `MACTIONS_KEEP_FAILED=1`
  (the app's "Keep a failed build's disk") only sets the failed disk aside in a
  `.win11-runner-base.bak.failed-<pid>` directory, which the app removes after
  the next successful rebuild.

A missing base blocks Windows provisioning, while a stale base can still run
jobs and only triggers the app's rebuild nudge; recipe-only rebuilds reuse the
cached ISO.

## Why Fusion is the only backend

The original investigation tried the free headless options before selecting
Fusion:

- Stock Homebrew QEMU with HVF hung inside Microsoft's ARM64 bootloader across
  the tested firmware and CPU combinations.
- UTM could boot Win11-ARM but exposed an Aqua/ScriptingBridge-oriented CLI with
  no headless create flow and required manual installation interaction.
- Fusion supplied the needed headless `vmrun` lifecycle plus snapshots and
  linked clones, and booted Win11-ARM reliably.

The Swift `WindowsVMCLI` protocol remains as a test seam, with `VMwareCLI` as its
sole conformer and `scripts/mactions-fusion-vm` as the lifecycle helper.

## Historical incidents and permanent lessons

### 2026-11-12: PowerShell 7.7 shipped without an MSI

Every rebuild failed about five minutes in with "guest powered off WITHOUT the
provisioning sentinel". PowerShell v7.7.0, published 2026-11-10, ships no `.msi`
for Windows (only `.zip` and `.msixbundle`; the whole 7.7 preview line had
none). `bootstrap.ps1` took `releases/latest`, found no win-arm64 MSI, skipped
pwsh, and the required-tools gate powered the guest off without the sentinel.

The gate logged its reason only 5 s before powering off, and the host copied the
guest transcript every 30 s, so the captured log stopped at the runner download,
before the real error. With "Keep a failed build's disk" on, each failed
attempt also stayed in place of the base: the app still showed the 2026-11-02
base as ready while the VM on disk had no snapshot to clone from, and the
second attempt backed up the first failed disk as the "prior base".

Now pwsh tracks the newest LTS, resolved from PowerShell's `tools/metadata.json`
`LTSReleaseTag` exactly as actions/runner-images does (7.6 today, the line
hosted pins), installs from the MSI after checking the release's
`hashes.sha256`, and falls back to the same release's zip if a future LTS ships
no MSI. Bootstrap failures report their reason to the host, and a failed
rebuild always restores the previous base.

### 2026-07-11: power-off was falsely accepted as success

Repeated 6–8 minute Windows exits were initially mistaken for normal runner
completion while jobs remained queued; the provider had flattened every guest
power-off to status 0, including no-JIT and runner-bootstrap failures.

Recipe v14 fixed the correctness gap with redundant VMware-Tools JIT delivery,
the explicit outcome file, failure-log capture, and the rule that a v14 power-off
without a marker fails; bases from v13 or earlier keep legacy behavior until the
rebuild nudge is followed.

### 2026-06-03: PowerShell 5.1 encoding broke provisioning

A BOM-less UTF-8 em dash was decoded through the Windows-1252 path into a smart
quote that terminated a string, making `bootstrap.ps1` fail before execution;
pwsh 7 parsed the same file successfully and therefore was not a sufficient
guard.

The permanent rule is pure ASCII plus a UTF-8 BOM for guest PowerShell, backed
by pre-snapshot verification, retained guest logs, `MACTIONS_KEEP_FAILED=1` for
disk forensics, and `MACTIONS_BUILD_GUI=1` for a visible diagnostic build.

### Git installation and hosted semantics

The ARM64 Git installer could display UI under nominal silent flags, while
MinGit lacked bash, so the base uses PortableGit's self-extractor and verifies
git, bash, and pwsh before snapshotting.

Recipe v13 moved Git to the hosted `C:\Program Files\Git` layout, restored the
hosted PATH composition, kept UAC enabled with elevate-without-prompting, and set
UTC; the complete recipe progression and accepted differences live in
PARITY.md.

## Downstream compatibility findings

### Workflow routing

Existing hosted workflows must replace `windows-11-arm` or `windows-latest`
with:

```yaml
runs-on: [self-hosted, Windows, mactions]
```

The JIT config must carry the same labels, and conditions on
`runner.environment == 'github-hosted'` change behavior on every self-hosted
runner.

### Azure Trusted Signing on Win11-ARM

`azure/trusted-signing-action@v2` was proven green on Mactions after separating
the native ARM64 action runtime from the emulated x64 signing dependency: the
workflow installs ARM64 .NET for the action and an x64 .NET 8 runtime exposed to
emulated processes through `DOTNET_ROOT_X64`.

The broader rule is that x64 binaries usually run under Windows emulation, but
npm packages with platform-keyed native binaries need a `win32-arm64` build or
another matrix leg; `wrangler`/`workerd` required publishing Windows artifacts
from a Linux leg for this reason.

## Remaining Windows follow-ups

- Build updates into a temporary VM and swap atomically so a failed rebuild
  cannot discard the working base.
- Make quit-time teardown concurrent after the orchestration ownership model can
  do so safely under Swift 6.
- Replace the manually synchronized `knownGAMajors` allowlist if UUP dump gains a
  false-positive-free GA signal.
- Consider per-clone guest credentials beyond the current outbound-only,
  one-job, destroy-on-exit threat model.
