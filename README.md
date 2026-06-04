# Mactions

A macOS menubar app that turns your Mac into an **on-demand, ephemeral GitHub Actions runner host**. Open it, runners come online for your repo; quit it, they go offline. Every runner is single-use: it registers, runs one job, deregisters, and is replaced while you're online.

> **Status: proof-of-concept.** The end-to-end loop works for **macOS/Linux** via a local runner process. VM isolation (Tart) is experimental. **Windows** is **opt-in** and **proven end to end on VMware Fusion** (2026-06-01): a `WindowsVMProvider` clones a throwaway Win11-ARM VM per job, the guest registers **outbound** to GitHub and runs **one** job, then powers off and the clone is destroyed. It's OFF by default behind a **"Set up Windows runner"** button (nothing heavy downloads or builds until you click it). The working backend is **VMware Fusion** (free since Nov 2024) — its `vmrun` CLI does headless clone/start/stop + snapshots and its EFI boots Win11-ARM, where stock QEMU's firmware hangs and UTM is GUI-bound. Fusion is a **manual download** (Broadcom portal — not brew-installable); the app detects it and installs the other free prerequisites (the UUP-dump ISO-converter tools + `xorriso`) via Homebrew — it **never** installs Homebrew itself (if `brew` is missing it points you at https://brew.sh). The Swift `VMwareCLI` provider drives the per-job loop, "Go online" auto-selects Fusion, and the **one-time base build is automated end to end** (`prepare-windows-image` → `fusion-windows-base`: no-prompt ISO, unattended install, VMware Tools/vmxnet3, bootstrap, snapshot) — and the **whole flow is proven via the UI**: the app built the base itself, ran a green Windows job on it, and tore every clone down on go-offline. The build also **verifies provisioning before snapshotting** and a **host-RAM cap** keeps concurrent VMs from thrashing the Mac. Built with **Swift 6** (strict concurrency). See [AGENTS.md](AGENTS.md) for the full picture, architecture, and roadmap.

## Quick start

```bash
swift run Mactions      # launches the menubar app (look in the menubar)
```

1. **Connect GitHub.** Either:
   - Paste a token (fastest): a classic PAT with `repo` scope, or a fine-grained token with **Administration: read & write** on the target repo, or
   - Sign in with the device flow: register an OAuth App (Settings → Developer settings → OAuth Apps, enable **Device Flow**), paste its client id, click **Sign in with GitHub**, approve the code in the browser.
2. **Set owner + repo** (e.g. `Kyter-com` / `sweep-collector`), labels, and how many runners.
3. **Go online.** Mactions downloads the runner agent on first use and brings ephemeral runners online. Reference them in a workflow with `runs-on: [self-hosted, macOS, mactions]` (match your labels).
4. **Quit the app** to take them offline (it deregisters them first).

Optional: click the **window button** (⊞) in the popover header to open the **dashboard** — a Pulse-style console with **Runners / History / Memory** tabs. Select a past run to see its **GitHub Actions job log inline** (fetched from GitHub, so it works for macOS *and* Windows runs); watch a running runner's **step checklist**; and see **live memory** (a gauge + sparkline + per-VM/runner breakdown). It's purely a viewer: it gives the app a dock icon while open and hides it again on close, and closing the window never takes runners offline (only quitting does). Built with Liquid Glass on macOS 26.

## Develop

```bash
swift build      # build
swift test       # unit tests (no network)
```

No external dependencies. The orchestration logic lives in the `MactionsCore` library (pure Foundation, fully unit-tested); the SwiftUI menubar app is a thin shell over it.

## Security

The default **local-process** runner has no isolation — only point it at **trusted / private** repos. VM-isolated runners (Tart for macOS/Linux, `WindowsVMProvider` for Windows) are the path for untrusted code and are still experimental. The GitHub token is stored in a `0600` file under `~/.mactions` (not the keychain — an unsigned dev build re-prompts on every keychain access; a signed build could use the keychain).

> **macOS code signing on a self-hosted runner — RESOLVED (2026-06-03):** the real per-run blocker was Mactions' own HOME redirect: `security` derives the user keychain search list from `$HOME`, so inside the throwaway clone the list collapsed to just the System keychain (0 identities) and electron-builder — even with `CSC_LINK` set — fell back to an **ad-hoc** signature that failed notarization, on *any* Mac. `LocalProcessProvider` now seeds the per-run search list with the host login keychain (it never touches the user's real one), and a release leg **signed + notarized green** on a personal Mac. Separately, a locked-down/**MDM-managed** Mac can still fail at the *host* level (`security find-identity -v -p codesigning` showing 0 valid for a good cert) — diagnose with that command; run release builds on a Mac where it shows your identity as valid.

> **Windows code signing (Azure Trusted Signing) on the ARM64 runner — RESOLVED (2026-06-03):** the `SignTool failed with exit code 3` was **not** a data-plane/RBAC rejection and not raw emulation — the Azure signing dlib is a mixed-mode **.NET 8** assembly, and the **x64** signtool+dlib (the only ones Microsoft ships; no arm64 dlib exists) need an **x64 .NET 8 runtime** under emulation, which the runner didn't have (only arm64 .NET 10; see `Azure/artifact-signing-action#138`). The workflow now installs the x64 .NET 8 runtime (`DOTNET_ROOT_X64`) and the installer **signs green on the Win11-ARM runner**. One related gotcha: `wrangler` (workerd) has **no win32-arm64 build**, so R2 uploads must run from another leg — the Windows leg hands its signed artifacts to a small ubuntu publish job. See [AGENTS.md](AGENTS.md) → Windows support.

See **[AGENTS.md](AGENTS.md)** for architecture, the per-OS reality (the macOS 2-VM cap, Linux containers, why Windows is hard), and the roadmap.
