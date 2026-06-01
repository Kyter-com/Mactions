# Mactions

A macOS menubar app that turns your Mac into an **on-demand, ephemeral GitHub Actions runner host**. Open it, runners come online for your repo; quit it, they go offline. Every runner is single-use: it registers, runs one job, deregisters, and is replaced while you're online.

> **Status: proof-of-concept.** The end-to-end loop works for **macOS/Linux** via a local runner process. VM isolation (Tart) is experimental. **Windows** is **opt-in** and **proven end to end on VMware Fusion** (2026-06-01): a `WindowsVMProvider` clones a throwaway Win11-ARM VM per job, the guest registers **outbound** to GitHub and runs **one** job, then powers off and the clone is destroyed. It's OFF by default behind a **"Set up Windows runner"** button (nothing heavy downloads or builds until you click it). The working backend is **VMware Fusion** (free since Nov 2024) — its `vmrun` CLI does headless clone/start/stop + snapshots and its EFI boots Win11-ARM, where stock QEMU's firmware hangs and UTM is GUI-bound. Fusion is a **manual download** (Broadcom portal — not brew-installable); the app detects it and installs the other free prerequisites (the UUP-dump ISO-converter tools + `xorriso`) via Homebrew — it **never** installs Homebrew itself (if `brew` is missing it points you at https://brew.sh). The Swift `VMwareCLI` provider drives the per-job loop, "Go online" auto-selects Fusion, and the **one-time base build is automated end to end** (`prepare-windows-image` → `fusion-windows-base`: no-prompt ISO, unattended install, VMware Tools/vmxnet3, bootstrap, snapshot). Remaining is a live app-driven run to confirm the automated base build boots clean. See [AGENTS.md](AGENTS.md) for the full picture, architecture, and roadmap.

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

## Develop

```bash
swift build      # build
swift test       # unit tests (no network)
```

No external dependencies. The orchestration logic lives in the `MactionsCore` library (pure Foundation, fully unit-tested); the SwiftUI menubar app is a thin shell over it.

## Security

The default **local-process** runner has no isolation — only point it at **trusted / private** repos. VM-isolated runners (Tart for macOS/Linux, `WindowsVMProvider` for Windows) are the path for untrusted code and are still experimental. The GitHub token is stored in a `0600` file under `~/.mactions` (not the keychain — an unsigned dev build re-prompts on every keychain access; a signed build could use the keychain).

See **[AGENTS.md](AGENTS.md)** for architecture, the per-OS reality (the macOS 2-VM cap, Linux containers, why Windows is hard), and the roadmap.
