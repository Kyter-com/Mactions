# Security Policy

Mactions turns a Mac into an on-demand host for ephemeral GitHub Actions
runners. It holds a GitHub token and executes CI jobs on your machine, so its
security model is worth understanding before you run it.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Use GitHub's private vulnerability reporting:
  <https://github.com/Kyter-com/Mactions/security/advisories/new>

Include the version or commit, your platform, and steps to reproduce. We aim to
acknowledge reports within a few days. This is a proof-of-concept project
maintained on a best-effort basis; there is no formal SLA.

## Supported versions

Only the latest release (and `main`) receive fixes. Mactions auto-updates via
Sparkle, so staying current is the expectation.

## Trust model and boundaries

**Mactions is intended for trusted, private repositories.** Treat it as
infrastructure that runs your own code, not as a hardened multi-tenant CI
service. Do not point public repositories or untrusted fork pull requests at a
Mactions fleet.

### Job isolation differs by platform

| Platform | Isolation | What a job can reach |
| --- | --- | --- |
| **macOS** | None — runs as your user on the host | Your user account: files, the on-disk token (below), and the login keychain. The per-run `HOME`/working directory is isolated for *hygiene*, not as a security sandbox. |
| **Linux** | Throwaway container (`--rm`) | Container-local only, but it **shares the host kernel** — a kernel-level escape would reach the host. |
| **Windows** | Throwaway VMware Fusion VM | Strongest isolation shipped here; the linked clone is destroyed after one job. |

A workflow job is arbitrary code. On the **macOS** provider that code runs with
your full user privileges and can read the GitHub token and your login keychain.
Only run trusted workflows there; use the Linux or Windows provider for anything
you do not fully control.

### GitHub token at rest

The token is stored in `~/.mactions/auth.token` as a plaintext file with `0600`
permissions (owner read/write only). It is **not** in the macOS Keychain:
unsigned/development builds have no stable code identity, so the Keychain
re-prompts on every read. A signed/notarized build can move this to the Keychain
— tracked on the roadmap. Because the file is owner-readable, any process (or
macOS job) running as your user can read it.

Runner registration uses GitHub **JIT (just-in-time) configs** — single-use,
single-job, self-deregistering — rather than long-lived registration tokens.

### Self-hosted CI workflows

The `selfhosted-smoke` and `win-smoke` workflows run on self-hosted runners and
are intentionally **`workflow_dispatch`-only** (manual; requires repo write
access). Do **not** add `pull_request`, `pull_request_target`, or `push`
triggers to any self-hosted workflow — that would let untrusted fork PRs execute
code on the maintainer's hardware.

### Software updates

Releases are signed with an Apple Developer ID, notarized by Apple, and stapled.
Updates are delivered by [Sparkle](https://sparkle-project.org) over HTTPS with
an EdDSA (ed25519) signature verified against the public key embedded in the app.
The private signing key is a CI-only secret and is never stored in this
repository.

### Download integrity

The macOS Actions-runner agent is verified against GitHub's published SHA-256
asset digest before it is extracted and run on the host. Other downloads that
occur **inside the isolated, throwaway VM or container** — the Windows ISO
obtained via UUP dump, in-guest tool installs, and the Linux runner image pulled
by tag — are fetched over HTTPS but are not independently hash-pinned. They are
scoped to the ephemeral guest that is destroyed after a single job.

### Windows base image hardening (intentional)

The throwaway Win11 base image deliberately disables Windows Defender, Windows
Update, and UAC elevation prompts, and uses a well-known throwaway local-admin
password with auto-logon. **This is intentional and safe for its context:** an
ephemeral, NAT-only (no inbound), single-job VM that is destroyed after every
run. Do not reuse this configuration for any persistent or internet-reachable
machine.
