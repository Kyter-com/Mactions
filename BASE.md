# Base Image Philosophy

Mactions runners should be as small as they can be while still behaving like real
GitHub Actions runners.

The base image is not meant to clone the full GitHub-hosted image. GitHub-hosted
Windows and macOS images include many preinstalled runtimes and tools because
they need to satisfy a broad public CI audience. Mactions has a different goal:
provide an ephemeral runner that is correct, predictable, and close enough to
GitHub's runner semantics, while leaving project-specific tools to the workflow.

## Principle

Bake in only what is needed for the runner to:

1. Register with GitHub and run one job.
2. Support the standard GitHub Actions shell and checkout expectations.
3. Match GitHub-hosted runner behavior where the difference is a runner/OS
   semantic, not a convenience package.
4. Stay reproducible, unattended, and easy to rebuild.

Everything else should normally be installed by the workflow with `setup-*`
actions, package managers, or project-specific install steps.

## What Belongs In The Base

Include tools or settings when they are part of the practical runner contract:

- The GitHub Actions runner agent.
- Git, Git LFS, and bash, because `actions/checkout` and `shell: bash` are common
  baseline expectations.
- The default Windows Actions shell support, currently PowerShell 7 / `pwsh`.
- Minimal OS settings that make shell execution behave like GitHub-hosted
  Windows, such as LocalMachine execution policy.
- Hypervisor or guest plumbing required for the ephemeral VM lifecycle, such as
  VMware Tools on Windows.
- Small safety or correctness settings that prevent false-success base images,
  failed unattended builds, or broken one-job execution.

These are allowed because they make the runner itself viable. They are not
included to save a workflow author a setup step.

## What Should Usually Stay Out

Do not preinstall broad tool stacks by default:

- Multiple Node versions.
- Multiple JDKs.
- Python, Go, Rust, Ruby, PHP, .NET SDKs, Android tools, browsers, databases, or
  Visual Studio.
- Cloud CLIs and deployment tools such as `gh`, `aws`, `az`, `kubectl`, or
  `pulumi`, unless a future product decision makes them opt-in.
- Build systems such as CMake, Ninja, LLVM, or Bazel by default.

If a workflow needs one of these, the workflow should say so explicitly. That
keeps the base small, makes dependencies visible in the repository, and avoids
turning Mactions into a second hosted-image maintenance project.

## GitHub Parity Stance

GitHub parity matters most for names, labels, runner contexts, shells, checkout,
OS behavior, and other semantics that a user reasonably expects when moving from
`windows-11-arm` or `macos-*` to Mactions.

Parity matters less for preinstalled convenience tools. A missing tool is
acceptable when it can be installed clearly in the workflow. A missing OS or
runner behavior is more important because users may not know how to fix it, and
because workflow steps can fail before user code has a chance to run.

Good parity changes are small, explicit, and explainable:

- They do not add large downloads to every base by default.
- They reduce surprising behavior differences.
- They preserve the ephemeral, one-job runner model.
- They can be tested without requiring a full VM build when possible.

## Decision Test

Before adding anything to a base image, ask:

1. Is this required for the runner agent, checkout, or standard shells to work?
2. Is this a GitHub-hosted OS/runner semantic rather than a convenience tool?
3. Would most workflows be unable to install this themselves at job time?
4. Does omitting it cause a surprising failure before the workflow can recover?
5. Can the change be kept small and covered by a focused test?

If the answer is no, prefer documenting the difference and installing the tool
inside the workflow.

## Examples

Adding LocalMachine PowerShell execution policy is a good base change: it matches
GitHub-hosted Windows shell behavior, adds no tool stack, and prevents explicit
`shell: powershell` steps from failing before user code runs.

Baking the `ImageOS` runner-identity token is a good base change: it is an
OS/runner semantic that `setup-*` actions and cache keys read — and that
whitelist-checking actions (e.g. `erlef/setup-beam`) hard-fail on when unset —
yet it adds no tool stack and is one env var per OS. The honest value is the
host's own identity where we have one (`macos<major>` on macOS, derived live;
`ubuntu24` is already baked by the official Linux runner image) and the closest
whitelist-safe proxy where we don't (`win25` on Windows, since GitHub publishes
no Win11/ARM token and a present-but-invalid value is worse than unset).
`ImageVersion` is the opposite call: it is an author-chosen cache-key fragment,
not a runner contract — nothing fails when it is unset — so the better move is to
leave it unset and document the difference rather than fabricate a hosted build
identity the minimal base does not have.

Preinstalling three Node versions is not a good default base change: workflows
can use `actions/setup-node`, and the required version belongs in the repository
that needs it.

Adding a package picker may be useful later, but it should remain opt-in. The
default runner should stay minimal.
