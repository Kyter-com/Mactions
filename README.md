# Mactions

A macOS menubar app that turns your Mac into an **on-demand, ephemeral GitHub Actions runner host**. Open it, runners come online for your repo; quit it, they go offline. Every runner is single-use: it registers, runs one job, deregisters, and is replaced while you're online.

> **Status: proof-of-concept.** The end-to-end loop works for **macOS/Linux** via a local runner process. VM isolation (Tart) is experimental. **Windows** is scaffolded and **opt-in** — a `WindowsVMProvider` clones a throwaway Win11-ARM VM per job (Parallels/UTM) and destroys it after. It's OFF by default behind a **"Set up Windows runner"** button (nothing heavy downloads or builds until you click it); that button auto-downloads the latest Win11 ARM64 ISO (UUP dump) and builds a one-time base image, and the app nudges you when a newer Windows build is out. Still **experimental and not yet live-verified end to end** (the ISO auto-download/convert, the VM boot, and a green Windows job are unproven). See [AGENTS.md](AGENTS.md) for the full picture, architecture, and roadmap.

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
