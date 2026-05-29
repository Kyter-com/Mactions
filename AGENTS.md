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
- ⛔ **Windows**: not built. See Roadmap for why it's the hard one.

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
- **`TartProvider`** (experimental) — clones a [Tart](https://tart.run) base image, boots it, SSHes in to launch the agent, deletes the clone on exit. Requires: Apple Silicon, `tart` installed, and a **base image** that already has the actions-runner at `~/actions-runner` plus an SSH login. Image prep is not automated yet.

### Per-OS reality (important)

- **macOS guests:** Tart via Virtualization.framework. Apple's EULA caps you at **2 concurrent macOS VMs per host**.
- **Linux guests:** easiest. Prefer a container (Colima/Lima/Docker) over a full VM for cleaner ephemerality. On Apple Silicon these are **arm64**; x64 Linux needs slow QEMU emulation, so label runners by arch and adjust workflows.
- **Windows guests:** the hard one. On Apple Silicon only **Windows 11 ARM** runs (UTM/QEMU/Parallels); x64 is emulation-only and slow. Tart doesn't do Windows. Honestly, a cheap always-on Windows box or a cloud VM the app starts/stops via API beats emulating locally.

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
swift test           # 12 unit tests (requests, device-flow guard, repo lister, orchestrator, cleanup)
swift run Mactions   # launches the menubar app for dev (look in the menubar)
```

`swift run` is fine for development; a distributable `.app` bundle (with `LSUIElement`, Developer ID signing, notarization) is a packaging step that doesn't exist yet — see Roadmap.

## Host hygiene (no leftover crap)

Ephemeral means the host is left as it was found. This is enforced, not hoped for — see `Cleanup.swift` and `LocalProcessProvider`:

- **Everything Mactions writes lives under one directory:** `~/.mactions/` (the cached agent template + a `runs/` dir + the token). A dot-dir in `$HOME`, **not** `~/Library/Application Support` — the Actions runner breaks on the space in "Application Support" (`exit 126`), so the work path must be space-free. One `rm -rf` reaps it all.
- **Per run:** each job runs in its own **APFS clone** of the cached agent at `runs/<runner-name>`. The job's `_work` checkout, `_tool`/`_actions` caches, `_diag` logs, and `.credentials` all live inside that clone, which is deleted the instant the agent exits. Nothing accumulates across runs. (APFS copy-on-write makes the clone near-instant and almost free on disk; non-APFS volumes fall back to a plain copy.)
- **On go-online:** `HostCleanup.sweepOrphans()` deletes any `runs/` leftovers and stray `mactions-*` Tart clones from a previous crash/force-quit.
- **On go-offline / quit:** `purgeRuns()` sweeps again (defensive).
- **Tart:** clones are deleted on agent exit and on `stop()`.
- **On demand:** the "Remove cached agent" button (offline) calls `purgeAll()` — removes the cached agent + all run files (not the token). "Sign out" deletes the token file.

The single persistent, intentional cache is the ~200 MB agent template (so restarts are fast); it's documented, reapable from the UI, and never the place jobs actually run.

## Conventions

- **`MactionsCore` has zero external dependencies** and no SwiftUI/AppKit import. Keep it that way — it's what makes the logic testable.
- **Network calls have pure request-builder counterparts** (`jitConfigRequest`, `deviceCodeRequest`, …) so they can be unit-tested without hitting the network. New endpoints should follow that split.
- **`RunnerOrchestrator` is `@MainActor`** and notifies the UI via an `onChange` callback, not Combine — the core stays UI-framework-free.
- Swift 5.9 tools, macOS 13+ target. Keep the build warning-clean.
- Runner names are prefixed `mactions-<host>-<rand>` so teardown can identify our own runners and never touch anyone else's.

## Roadmap

- **Windows** support (Win11-ARM VM provider, image prep, or "start a cloud/remote box" provider).
- **Scale-from-zero:** instead of N idle runners, listen for `workflow_job` queued events (webhook or API poll) and provision on demand. This is what ARC does.
- **Distributable `.app`:** Xcode/`xcodebuild` bundle step, `LSUIElement`, Developer ID + notarization, and a Login Item so it can auto-start.
- **Tart image automation:** a `mactions prepare-image` flow that bakes the runner + SSH into a base image.
- **Org runners + multiple repos** (today it's one repo at a time, repo-level).
- **Tart provider in the UI** once image prep is automated.

## Caveats

- A laptop is not an always-on CI host: sleep/lid-close interrupts jobs; nothing runs while the app is closed. That's the intended model ("run my CI while I'm working"), not a 24/7 fleet.
- Running untrusted PR code on your personal machine is a real risk. The local provider has **no isolation** — use it only for trusted/private repos until the VM provider is production-ready.
