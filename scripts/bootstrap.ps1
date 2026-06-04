<#
  bootstrap.ps1 - runs INSIDE the Windows 11 ARM guest on first logon
  (invoked once by autounattend.xml's FirstLogonCommands, at BUILD time).

  MAINTAINER NOTE: any change here that makes an ALREADY-BUILT base functionally
  stale (e.g. the MinGit->PortableGit switch that added bash) must bump
  PROVISIONING_RECIPE_VERSION in prepare-windows-image (mirrored as
  WindowsImage.currentProvisioningRecipeVersion; a unit test keeps them equal),
  so the app flags existing bases as needing a rebuild.

  Turns a fresh Win11-ARM install into a Mactions runner base image for the
  HEADLESS / OUTBOUND-REGISTRATION model (no inbound SSH, no guest IP discovery):
    1. Download + extract the LATEST win-arm64 actions-runner agent to
       C:\actions-runner (short root path to dodge Windows MAX_PATH on deep
       node_modules trees).
    2. Drop C:\setup\run-job.ps1 (the PER-CLONE runtime) and register a recurring
       logon Scheduled Task that runs it on EVERY boot.
    3. Disable UAC for this disposable guest so the task gets a full admin token.

  Per job, the host clones this base, injects a tiny config ISO carrying the JIT
  registration (VMware Fusion: the clone's sata0:0 CD is wired to it at clone
  time), and boots the clone headless. run-job.ps1 then:
    - finds the JIT on the config disc (by volume label / drive scan),
    - runs `run.cmd --jitconfig <JIT>` for exactly ONE job (registers OUTBOUND to
      GitHub, auto-deregisters when done),
    - powers the VM off. The host detects completion purely by polling VM power
      state, then deletes the clone. Nothing inbound, nothing left behind.

  After this script finishes, SHUT THE VM DOWN - the powered-off VM is the
  pristine base image. (The first clone boot applies the EnableLUA=0 reboot-gated
  change.) Runs under in-box Windows PowerShell 5.1, so everything here is
  5.1-compatible.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # PS 5.1 IWR progress bar throttles large -OutFile downloads ~10x
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Single-run guard. At BUILD time this script is launched by TWO independent paths so a
# single fragile trigger can't leave the base un-provisioned: the specialize-pass RunOnce
# (the reliable launcher) and the oobeSystem FirstLogonCommands (fragile on Win11 24H2/25H2
# - verified live: OOBE completed but FirstLogonCommands never fired). If both fire on the
# same logon, the second must no-op, not double-install. New-Item -ErrorAction Stop is the
# atomic winner-picker across that race.
New-Item -ItemType Directory -Force -Path 'C:\setup' | Out-Null
try { $null = New-Item -ItemType File -Path 'C:\setup\.bootstrap-started' -ErrorAction Stop }
catch {
  # Only an EXISTING lock means "another launcher won". Any other failure (e.g. access
  # denied under a non-elevated token) must be loud, not silently read as already-started.
  if (Test-Path 'C:\setup\.bootstrap-started') {
    Write-Host 'bootstrap.ps1 already started by another launcher - exiting to avoid a double-run.'
    exit 0
  }
  throw
}

$RunnerRoot = 'C:\actions-runner'

# Optional extra packages selected in the Mactions UI (installed in section 0c).
# prepare-windows-image swaps this LINE in the STAGED copy at ISO-build time
# (anchored on the marker comment - do not remove it); the repo default stays
# empty. Ids map 1:1 to WindowsImage.packageCatalog in the app - a unit test
# keeps the two in lockstep.
$SelectedPackages = @()  # MACTIONS-PACKAGES-LINE

# Retry a network operation through transient blips (DNS / connection reset /
# 5xx / a momentary drop) with linear backoff, so a brief network hiccup during
# the (long) base build doesn't fail the whole image. Throws a clear message only
# after exhausting all tries.
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [ValidateRange(1, [int]::MaxValue)][int]$Tries = 5,  # >=1 so the loop always runs (never silently returns $null)
    [int]$DelaySeconds = 5,
    [string]$What = 'network operation'
  )
  for ($i = 1; $i -le $Tries; $i++) {
    try { return (& $Action) }
    catch {
      if ($i -ge $Tries) { throw "$What failed after $i attempts: $($_.Exception.Message)" }
      Write-Host ("  {0} failed (attempt {1}/{2}): {3} - retrying in {4}s..." -f `
        $What, $i, $Tries, $_.Exception.Message, ($DelaySeconds * $i))
      Start-Sleep -Seconds ($DelaySeconds * $i)
    }
  }
}

# Durable build transcript: survives in the base disk, and fusion-windows-base
# copies it out to ~/.mactions/logs if the build times out. Best-effort - never
# fail the build over a logging hiccup.
try {
  New-Item -ItemType Directory -Force -Path 'C:\setup\logs' | Out-Null
  Start-Transcript -Path 'C:\setup\logs\bootstrap.log' -Force | Out-Null
} catch { }

Write-Host '== Mactions Windows base image bootstrap (outbound/headless) =='

# --- 0a. Networking: on the VMware Fusion base build, the guest NIC is vmxnet3,
# which has NO in-box Win11-ARM driver - so there is NO network until VMware
# Tools installs it. Everything below downloads from the internet, so we MUST
# bring the network up first. Install Tools silently from its attached CD (the
# Fusion isoimages ISO mounts with volume label "VMware Tools" + a root
# setup.exe), then wait for outbound connectivity. This whole block is a no-op on
# the other backends (no Tools CD present) and on a re-run (Tools already
# installed), so the shared bootstrap stays correct everywhere.
function Test-Outbound {
  try {
    $r = Invoke-WebRequest -Uri 'https://api.github.com/zen' -UseBasicParsing -TimeoutSec 10
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

if (-not (Test-Outbound)) {
  if (-not (Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue)) {
    $toolsVol = Get-Volume -ErrorAction SilentlyContinue |
      Where-Object { $_.FileSystemLabel -eq 'VMware Tools' -and $_.DriveLetter } |
      Select-Object -First 1
    $setup = if ($toolsVol) { "$($toolsVol.DriveLetter):\setup.exe" } else { $null }
    if ($setup -and (Test-Path $setup)) {
      Write-Host 'Installing VMware Tools (silent, no reboot) to bring up vmxnet3 networking...'
      try {
        # InstallShield wrapper: /S = silent setup, /v passes the quoted args to
        # msiexec; /qn = no MSI UI, REBOOT=R = suppress the reboot (the vmxnet3
        # NIC driver binds via PnP without one). Routed through cmd so the
        # embedded /v"..." quoting survives.
        & "$env:ComSpec" /c "`"$setup`" /S /v`"/qn REBOOT=R`"" 2>&1 | Out-Null
        Write-Host "VMware Tools setup exit: $LASTEXITCODE"
      } catch {
        Write-Warning "VMware Tools install failed (continuing; network wait will decide): $_"
      }
    }
  }
  Write-Host 'Waiting for outbound network (vmxnet3 binds after the Tools PnP driver install)...'
  # 300s (was 180): tolerate a slow Tools/PnP NIC bring-up + transient DNS before
  # giving up. Test-Outbound swallows per-probe errors, so a momentary drop just
  # keeps the loop waiting rather than aborting the build.
  $deadline = (Get-Date).AddSeconds(300)
  while ((Get-Date) -lt $deadline -and -not (Test-Outbound)) { Start-Sleep -Seconds 5 }
  if (-not (Test-Outbound)) {
    throw 'No outbound network after 300s. On VMware Fusion this means the vmxnet3 driver never bound (VMware Tools may need a reboot on this build); cannot download the runner agent.'
  }
  Write-Host 'Network is up.'
}

# --- 0. Dev tooling GitHub Actions workflows commonly need -------------------
# We install these BEFORE the runner agent so a failure here is loud and
# obvious (the agent install is the cheap fast step). All are silent installs
# baked into the BASE image once - per-job clones inherit them via the qcow2
# overlay, so workflows pay no install cost.
#
# Tools we install:
#   - Git for Windows: actions/checkout falls back to a slow REST tarball
#     download when `git` isn't on PATH. With git installed, checkout uses a
#     real clone and respects fetch-depth, submodules, LFS, etc.
#   - 7-Zip: common need for archive actions; also a fast unzip path.
#   - PowerShell 7 (pwsh): the default Windows-runner shell since 2019; many
#     actions hard-require `shell: pwsh` (e.g. azure/trusted-signing-action).
#     Windows ships only PS 5.1, so we bake pwsh in - the same reasoning that
#     put bash (via PortableGit) in the base: shells belong in the image.
#
# Everything else from GitHub's hosted windows-11-arm image is OPT-IN via the
# Mactions UI ($SelectedPackages above): toolcache entries (node/Python/Go -
# section 0b) and global tools (gh, CMake, .NET, Java, jq/yq - section 0c).
# Unselected tools still work in workflows via actions/setup-* at job time -
# the base just stays lean.
function Install-Msi {
  param([Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$LocalName,
        [string[]]$Properties = @())   # extra msiexec PROPERTY=value args (e.g. ADD_CMAKE_TO_PATH=System)
  $tmp = Join-Path $env:TEMP $LocalName
  if (Test-Path $tmp) { Remove-Item $tmp -Force }
  Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
  $msiArgs = @('/i', $tmp, '/quiet', '/norestart') + $Properties
  $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
  Remove-Item $tmp -Force
  if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "msiexec /i $LocalName failed with exit code $($proc.ExitCode)"
  }
}
function Install-Exe {
  param([Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$LocalName,
        [string[]]$Args = @('/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES'))
  $tmp = Join-Path $env:TEMP $LocalName
  if (Test-Path $tmp) { Remove-Item $tmp -Force }
  Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
  $proc = Start-Process $tmp -ArgumentList $Args -Wait -PassThru
  Remove-Item $tmp -Force
  if ($proc.ExitCode -ne 0) { throw "$LocalName installer failed with exit code $($proc.ExitCode)" }
}

# Git for Windows (ARM64) - use the PortableGit 7-Zip self-extractor. NOT the
# Inno installer and NOT MinGit. Three-way rationale:
#   - `Git-*-arm64.exe` (Inno) pops a GUI under an unattended FirstLogonCommands
#     session on ARM64 (its /VERYSILENT is honored on x64 but the ARM64 build
#     surfaces a window with no desktop to click) -> STALLS the base build.
#   - MinGit (the minimal redistributable) extracts silently and gives git.exe,
#     but ships NO `bash`. GitHub Actions' `shell: bash` (the default shell for
#     cross-platform `run:` scripts) then fails on the runner with
#     "bash: command not found" -> any workflow with a bash step is dead on
#     Windows. (This bit a real release: every `shell: bash` step failed.)
#   - PortableGit IS the full Git for Windows (git.exe + a working bash/MSYS),
#     shipped as a 7-Zip SFX. With `-y` it auto-confirms and exits on its own
#     (unlike the Inno GUI it never waits for a click), so it's safe unattended.
# We add BOTH \cmd (git.exe, for actions/checkout) and \bin (bash.exe, for
# `shell: bash`) to the MACHINE PATH so the runner service resolves both.
Write-Host 'Installing Git for Windows (ARM64, PortableGit + bash)...'
try {
  $gitRel = Invoke-WithRetry -What 'Git-for-Windows release lookup' {
    Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
      -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
  }
  $gitAsset = $gitRel.assets |
    Where-Object { $_.name -match '^PortableGit-.*-arm64\.7z\.exe$' } |
    Select-Object -First 1
  if (-not $gitAsset) {
    Write-Warning "No PortableGit ARM64 asset in release $($gitRel.tag_name); skipping Git install."
  } else {
    $gitDir = 'C:\Git'
    $gitSfx = Join-Path $env:TEMP 'portablegit-arm64.7z.exe'
    if (Test-Path $gitSfx) { Remove-Item $gitSfx -Force }
    # Retry the download - git+bash are REQUIRED (verified before the sentinel below),
    # so a transient blip here must not silently skip Git and produce a base that fails
    # `actions/checkout` (falls back to a slow REST tarball) and every `shell: bash` step.
    Invoke-WithRetry -What 'PortableGit download' {
      Invoke-WebRequest -Uri $gitAsset.browser_download_url -OutFile $gitSfx -UseBasicParsing
    }
    if (Test-Path $gitDir) { Remove-Item $gitDir -Recurse -Force }
    # 7-Zip SFX flags: -y auto-confirms (no prompt, no wait), -o<dir> sets the
    # extraction target (no space after -o). PortableGit then runs its own
    # non-interactive post-install to wire up the MSYS environment bash needs.
    $proc = Start-Process $gitSfx -ArgumentList '-y', "-o$gitDir" -Wait -PassThru
    Remove-Item $gitSfx -Force
    if ($proc.ExitCode -ne 0) { throw "PortableGit SFX failed with exit code $($proc.ExitCode)" }
    $gitCmd = Join-Path $gitDir 'cmd'
    $gitBin = Join-Path $gitDir 'bin'
    if (-not (Test-Path (Join-Path $gitCmd 'git.exe'))) {
      throw "git.exe not found under $gitCmd after PortableGit extract"
    }
    if (-not (Test-Path (Join-Path $gitBin 'bash.exe'))) {
      throw "bash.exe not found under $gitBin after PortableGit extract (shell: bash would break)"
    }
    $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($p in @($gitCmd, $gitBin)) {
      if ($machPath -notlike "*$p*") { $machPath = $machPath.TrimEnd(';') + ';' + $p }
    }
    [Environment]::SetEnvironmentVariable('Path', $machPath, 'Machine')
    $env:Path = $env:Path + ';' + $gitCmd + ';' + $gitBin
    & "$gitCmd\git.exe" --version | Write-Host
    & "$gitBin\bash.exe" -c 'echo "bash OK: $BASH_VERSION"' | Write-Host
  }
} catch {
  Write-Warning "Git install failed (continuing): $_"
}

# 7-Zip ARM64 - small, fast, useful for many actions. NOTE: 7-Zip ships NO
# ARM64 .msi (only x64) - the ARM64 build is an NSIS .exe that takes /S (NOT
# Inno's /VERYSILENT). There's no "latest" URL alias, so the version is pinned
# and must be bumped manually (check https://www.7-zip.org/download.html).
# Non-fatal: the try/catch lets the runner come up without it.
$SevenZipUrl = 'https://www.7-zip.org/a/7z2601-arm64.exe'   # MANUAL pin (no "latest" alias) - bump at https://www.7-zip.org/download.html
Write-Host 'Installing 7-Zip (ARM64)...'
try {
  Install-Exe -Url $SevenZipUrl -LocalName '7z-arm64.exe' -Args @('/S')
} catch {
  # Non-fatal: the runner comes up without 7-Zip. The pinned version can 404 once
  # 7-Zip ships a newer ARM64 build - say so explicitly so it's obvious the base
  # is missing 7-Zip (and which URL to bump) rather than a silent omission.
  Write-Warning "7-Zip install skipped (continuing without it): $SevenZipUrl failed - $_. If this is a 404, bump the pinned version in bootstrap.ps1."
}

# PowerShell 7 (ARM64) - the official win-arm64 .msi. GitHub Actions' `shell: pwsh`
# (and actions like azure/trusted-signing-action) need PowerShell 7; Windows ships
# only PS 5.1. The MSI is the supported UNATTENDED install: `/quiet` is fully silent
# (no GUI to stall the headless FirstLogonCommands session) and `ADD_PATH=1` puts
# %ProgramFiles%\PowerShell\7 on the MACHINE PATH, so the runner service resolves
# `pwsh` on every clone boot - no manual PATH edit (which the zip would require).
# Resolve the latest release at build time (no pin), same as PortableGit / the
# runner agent. Inline headers because $ghHeaders isn't defined until the agent
# section below. Non-fatal: the runner still comes up without it.
Write-Host 'Installing PowerShell 7 (ARM64, official MSI)...'
try {
  $pwshRel = Invoke-WithRetry -What 'PowerShell release lookup' {
    Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' `
      -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
  }
  $pwshAsset = $pwshRel.assets |
    Where-Object { $_.name -match '^PowerShell-.*-win-arm64\.msi$' } |
    Select-Object -First 1
  if (-not $pwshAsset) {
    Write-Warning "No win-arm64 .msi in PowerShell release $($pwshRel.tag_name); skipping pwsh install."
  } else {
    $pwshMsi = Join-Path $env:TEMP 'powershell-arm64.msi'
    if (Test-Path $pwshMsi) { Remove-Item $pwshMsi -Force }
    # Retry - pwsh is REQUIRED (verified before the sentinel below): actions like
    # azure/trusted-signing-action default to `shell: pwsh`, absent in stock Windows.
    Invoke-WithRetry -What 'PowerShell 7 download' {
      Invoke-WebRequest -Uri $pwshAsset.browser_download_url -OutFile $pwshMsi -UseBasicParsing
    }
    # /quiet = no UI (safe headless); ADD_PATH=1 = add %ProgramFiles%\PowerShell\7
    # to the MACHINE PATH; /norestart = never reboot mid-build.
    $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
      '/i', $pwshMsi, '/quiet', '/norestart', 'ADD_PATH=1'
    Remove-Item $pwshMsi -Force
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
      throw "PowerShell 7 MSI failed with exit code $($proc.ExitCode)"
    }
    $pwshDir = Join-Path $env:ProgramFiles 'PowerShell\7'
    $pwshExe = Join-Path $pwshDir 'pwsh.exe'
    if (-not (Test-Path $pwshExe)) {
      throw "pwsh.exe not found under $pwshDir after MSI install"
    }
    # ADD_PATH=1 already wrote the MACHINE PATH; belt-and-suspenders (idempotent),
    # exactly like the PortableGit cmd/bin dirs above, so per-clone runner sessions
    # resolve `pwsh`.
    $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machPath -notlike "*$pwshDir*") {
      $machPath = $machPath.TrimEnd(';') + ';' + $pwshDir
      [Environment]::SetEnvironmentVariable('Path', $machPath, 'Machine')
    }
    $env:Path = $env:Path + ';' + $pwshDir
    & $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | Write-Host
  }
} catch {
  Write-Warning "PowerShell 7 install failed (continuing): $_"
}

# --- 0b. GitHub-hosted toolcache entries (selected in the Mactions UI) -------
# Pre-warm C:\hostedtoolcache\windows with tool versions from GitHub's own
# hosted `windows-11-arm` runner image, installed the SAME way GitHub installs
# them (this mirrors Install-Toolset.ps1 in actions/runner-images): for each
# selected entry, read the actions/*-versions manifest, download the matching
# win32 archive, and run the setup.ps1 each archive embeds - it self-installs
# into the toolcache and writes the `<arch>.complete` marker that
# actions/setup-node / -python / -go check before downloading anything.
#
# Why: per-job clones are throwaway, so without this EVERY job that uses a
# setup-* action re-downloads its tool through NAT. Pre-warmed, those actions
# hit the cache instantly AND resolve the exact versions GitHub's hosted
# windows-11-arm runners resolve - the same compatibility story. Anything NOT
# selected still works: setup-* downloads it at job time, just slower.
#
# The available ids mirror images/windows/toolsets/toolset-win-11-arm64.json in
# actions/runner-images as of recipe v5 (2026-06). Python x64 is offered under
# emulation exactly as GitHub ships it (some wheels are x64-only). When
# refreshing: re-check that file and bump the recipe version.
#
# SELECTED entries are FATAL on failure (after retries): a silently missing one
# would snapshot a base that LOOKS provisioned but lacks what the user asked
# for - the same silent-partial-base failure mode the v4 git/bash/pwsh
# verification closed. Markers are also re-verified before the sentinel below.
$ToolCacheDir = 'C:\hostedtoolcache\windows'
New-Item -ItemType Directory -Force -Path $ToolCacheDir | Out-Null
# Both names, machine-wide, ALWAYS (selection or not): the actions runner reads
# RUNNER_TOOL_CACHE, the embedded setup.ps1 scripts read AGENT_TOOLSDIRECTORY
# first, and GitHub's hosted images set both. With nothing pre-warmed, setup-*
# actions simply populate this dir per job (clone-ephemeral) instead of _work\_tool.
[Environment]::SetEnvironmentVariable('RUNNER_TOOL_CACHE', $ToolCacheDir, 'Machine')
[Environment]::SetEnvironmentVariable('AGENT_TOOLSDIRECTORY', $ToolCacheDir, 'Machine')
$env:RUNNER_TOOL_CACHE = $ToolCacheDir
$env:AGENT_TOOLSDIRECTORY = $ToolCacheDir

function Install-ToolcacheVersion {
  param(
    [Parameter(Mandatory)][object]$Manifest,   # parsed versions-manifest.json (newest-first)
    [Parameter(Mandatory)][string]$Tool,       # toolcache dir name: 'node' / 'Python' / 'go'
    [Parameter(Mandatory)][string]$Spec,       # version spec, e.g. '22.*'
    [Parameter(Mandatory)][string]$Arch        # 'arm64' / 'x64'
  )
  # First match = latest matching (the manifest is ordered newest-first). The
  # [version] cast filters out prerelease tags (e.g. 3.14.0-rc.2) - same filter
  # GitHub's Install-Toolset.ps1 applies. Exact -eq on arch also excludes the
  # '-freethreaded' Python variants.
  $entry = $Manifest |
    Where-Object { $_.version -like $Spec -and ($_.version -as [version]) } |
    Select-Object -First 1
  if (-not $entry) { throw "no $Tool version matching '$Spec' in the versions manifest" }
  $file = $entry.files |
    Where-Object { $_.platform -eq 'win32' -and $_.arch -eq $Arch } |
    Select-Object -First 1
  if (-not $file) { throw "no win32/$Arch asset for $Tool $($entry.version) in the versions manifest" }
  Write-Host ("  {0} {1} ({2}): {3}" -f $Tool, $entry.version, $Arch, $file.filename)
  $zip = Join-Path $env:TEMP $file.filename
  $dir = Join-Path $env:TEMP ([System.IO.Path]::GetFileNameWithoutExtension($file.filename))
  if (Test-Path $zip) { Remove-Item $zip -Force }
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  Invoke-WithRetry -What "$Tool $($entry.version) ($Arch) download" {
    Invoke-WebRequest -Uri $file.download_url -OutFile $zip -UseBasicParsing
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
  Remove-Item $zip -Force
  # Each actions/*-versions archive embeds setup.ps1: it installs into
  # AGENT_TOOLSDIRECTORY (set above) and writes the .complete marker itself.
  # Run from inside the extracted dir - the script uses relative paths.
  Push-Location $dir
  try { & (Join-Path $dir 'setup.ps1') | Out-Null } finally { Pop-Location }
  Remove-Item $dir -Recurse -Force
  # Verify the marker the setup script is contracted to write - a tool that
  # "installed" without it would make setup-* actions re-download anyway.
  $marker = Join-Path $ToolCacheDir (Join-Path $Tool (Join-Path $entry.version "$Arch.complete"))
  if (-not (Test-Path $marker)) {
    throw "$Tool $($entry.version) $Arch setup.ps1 ran but the completion marker is missing: $marker"
  }
}

# Every offerable toolcache entry, keyed by the catalog id the UI uses. The
# matrix mirrors toolset-win-11-arm64.json; the UI shows one checkbox per id.
$NodeManifestUrl   = 'https://raw.githubusercontent.com/actions/node-versions/main/versions-manifest.json'
$PythonManifestUrl = 'https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json'
$GoManifestUrl     = 'https://raw.githubusercontent.com/actions/go-versions/main/versions-manifest.json'
$toolcacheCatalog = @{
  'node-22'         = @{ Tool = 'node';   Url = $NodeManifestUrl;   Arch = 'arm64'; Spec = '22.*' }
  'node-24'         = @{ Tool = 'node';   Url = $NodeManifestUrl;   Arch = 'arm64'; Spec = '24.*' }
  'python-3.12'     = @{ Tool = 'Python'; Url = $PythonManifestUrl; Arch = 'arm64'; Spec = '3.12.*' }
  'python-3.13'     = @{ Tool = 'Python'; Url = $PythonManifestUrl; Arch = 'arm64'; Spec = '3.13.*' }
  'python-3.13-x64' = @{ Tool = 'Python'; Url = $PythonManifestUrl; Arch = 'x64';   Spec = '3.13.*' }
  'python-3.14'     = @{ Tool = 'Python'; Url = $PythonManifestUrl; Arch = 'arm64'; Spec = '3.14.*' }
  'go-1.22'         = @{ Tool = 'go';     Url = $GoManifestUrl;     Arch = 'arm64'; Spec = '1.22.*' }
  'go-1.23'         = @{ Tool = 'go';     Url = $GoManifestUrl;     Arch = 'arm64'; Spec = '1.23.*' }
  'go-1.24'         = @{ Tool = 'go';     Url = $GoManifestUrl;     Arch = 'arm64'; Spec = '1.24.*' }
  'go-1.25'         = @{ Tool = 'go';     Url = $GoManifestUrl;     Arch = 'arm64'; Spec = '1.25.*' }
}
$selectedToolcache = @($SelectedPackages | Where-Object { $toolcacheCatalog.ContainsKey($_) })
if ($selectedToolcache.Count) {
  Write-Host ("Pre-warming the GitHub Actions toolcache ({0} selected)..." -f $selectedToolcache.Count)
  # Fetch each distinct manifest once, then install every selected entry.
  $manifests = @{}
  foreach ($id in $selectedToolcache) {
    $entry = $toolcacheCatalog[$id]
    if (-not $manifests.ContainsKey($entry.Url)) {
      $manifests[$entry.Url] = Invoke-WithRetry -What "$($entry.Tool) versions-manifest fetch" {
        Invoke-RestMethod $entry.Url -Headers @{ 'User-Agent' = 'mactions' }
      }
    }
    Install-ToolcacheVersion -Manifest $manifests[$entry.Url] -Tool $entry.Tool -Spec $entry.Spec -Arch $entry.Arch
  }
  Write-Host 'Toolcache pre-warm complete.'
}

# --- 0c. Optional tools (selected in the Mactions UI) ------------------------
# The non-toolcache half of the catalog: CLIs/SDKs GitHub's hosted
# windows-11-arm image preinstalls globally. One `switch` case per catalog id
# (the app's WindowsImage.packageCatalog mirrors these; a unit test pins the
# parity). SELECTED tools are FATAL on failure after retries - same reasoning
# as the toolcache above - and each registers verify probes in $packageProbes,
# re-checked before the provisioning sentinel.
$packageProbes = @{}
foreach ($pkg in $SelectedPackages) {
  if ($toolcacheCatalog.ContainsKey($pkg)) { continue }  # handled in section 0b
  Write-Host "Installing selected tool '$pkg'..."
  switch ($pkg) {
    'gh' {
      # GitHub CLI - native ARM64 MSI from the latest cli/cli release (the MSI
      # wires up the machine PATH itself).
      $rel = Invoke-WithRetry -What 'GitHub CLI release lookup' {
        Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest' `
          -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
      }
      $a = $rel.assets | Where-Object { $_.name -match '^gh_.*_windows_arm64\.msi$' } | Select-Object -First 1
      if (-not $a) { throw "no windows_arm64 .msi in cli/cli release $($rel.tag_name)" }
      Invoke-WithRetry -What 'GitHub CLI install' {
        Install-Msi -Url $a.browser_download_url -LocalName 'gh-arm64.msi'
      }
      $packageProbes['gh'] = @(@{ Dir = 'C:\Program Files\GitHub CLI'; File = 'gh.exe' })
    }
    'cmake' {
      # CMake - native ARM64 MSI from the latest Kitware release.
      # ADD_CMAKE_TO_PATH=System puts cmake on the machine PATH.
      $rel = Invoke-WithRetry -What 'CMake release lookup' {
        Invoke-RestMethod 'https://api.github.com/repos/Kitware/CMake/releases/latest' `
          -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
      }
      $a = $rel.assets | Where-Object { $_.name -match '^cmake-.*-windows-arm64\.msi$' } | Select-Object -First 1
      if (-not $a) { throw "no windows-arm64 .msi in CMake release $($rel.tag_name)" }
      Invoke-WithRetry -What 'CMake install' {
        Install-Msi -Url $a.browser_download_url -LocalName 'cmake-arm64.msi' -Properties @('ADD_CMAKE_TO_PATH=System')
      }
      $packageProbes['cmake'] = @(@{ Dir = 'C:\Program Files\CMake'; File = 'cmake.exe' })
    }
    'dotnet-8' {
      # .NET SDK 8 (LTS), native arm64, via Microsoft's official dotnet-install
      # script - the same family GitHub preinstalls. DOTNET_ROOT + machine PATH
      # so both raw `dotnet` calls and actions/setup-dotnet resolve it.
      $di = Join-Path $env:TEMP 'dotnet-install.ps1'
      Invoke-WithRetry -What 'dotnet-install.ps1 download' {
        Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $di -UseBasicParsing
      }
      $dotnetDir = Join-Path $env:ProgramFiles 'dotnet'
      Invoke-WithRetry -What '.NET 8 SDK install' {
        & $di -Channel '8.0' -Architecture 'arm64' -InstallDir $dotnetDir | Out-Null
      }
      Remove-Item $di -Force
      $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
      if ($machPath -notlike "*$dotnetDir*") {
        [Environment]::SetEnvironmentVariable('Path', $machPath.TrimEnd(';') + ';' + $dotnetDir, 'Machine')
      }
      [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetDir, 'Machine')
      $packageProbes['dotnet-8'] = @(@{ Dir = $dotnetDir; File = 'dotnet.exe' })
    }
    'java-21' {
      # Temurin JDK 21 (LTS), native windows/aarch64, via the Adoptium API (the
      # same distribution GitHub's images default to). The MSI features wire up
      # PATH + JAVA_HOME.
      $msi = Join-Path $env:TEMP 'temurin-21-arm64.msi'
      Invoke-WithRetry -What 'Temurin 21 download' {
        Invoke-WebRequest 'https://api.adoptium.net/v3/installer/latest/21/ga/windows/aarch64/jdk/hotspot/normal/eclipse' `
          -OutFile $msi -UseBasicParsing
      }
      $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
        '/i', $msi, '/quiet', '/norestart', 'ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome'
      Remove-Item $msi -Force
      if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { throw "Temurin 21 MSI failed with exit code $($proc.ExitCode)" }
      $packageProbes['java-21'] = @(@{ Dir = 'C:\Program Files\Eclipse Adoptium'; File = 'java.exe' })
    }
    'java-23' {
      # Temurin JDK 23 - the second Java GitHub's windows-11-arm image ships.
      $msi = Join-Path $env:TEMP 'temurin-23-arm64.msi'
      Invoke-WithRetry -What 'Temurin 23 download' {
        Invoke-WebRequest 'https://api.adoptium.net/v3/installer/latest/23/ga/windows/aarch64/jdk/hotspot/normal/eclipse' `
          -OutFile $msi -UseBasicParsing
      }
      $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
        '/i', $msi, '/quiet', '/norestart', 'ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome'
      Remove-Item $msi -Force
      if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { throw "Temurin 23 MSI failed with exit code $($proc.ExitCode)" }
      $packageProbes['java-23'] = @(@{ Dir = 'C:\Program Files\Eclipse Adoptium'; File = 'java.exe' })
    }
    'jq-yq' {
      # jq + yq single-binary CLIs into C:\tools (on PATH). jq ships no
      # windows-arm64 build - the amd64 .exe runs under emulation, exactly how
      # GitHub ships x64-only tools on their ARM image. yq is native arm64.
      $toolsDir = 'C:\tools'
      New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
      $rel = Invoke-WithRetry -What 'jq release lookup' {
        Invoke-RestMethod 'https://api.github.com/repos/jqlang/jq/releases/latest' `
          -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
      }
      $a = $rel.assets | Where-Object { $_.name -eq 'jq-windows-amd64.exe' } | Select-Object -First 1
      if (-not $a) { throw "no jq-windows-amd64.exe in jq release $($rel.tag_name)" }
      Invoke-WithRetry -What 'jq download' {
        Invoke-WebRequest $a.browser_download_url -OutFile (Join-Path $toolsDir 'jq.exe') -UseBasicParsing
      }
      $rel = Invoke-WithRetry -What 'yq release lookup' {
        Invoke-RestMethod 'https://api.github.com/repos/mikefarah/yq/releases/latest' `
          -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
      }
      $a = $rel.assets | Where-Object { $_.name -eq 'yq_windows_arm64.exe' } | Select-Object -First 1
      if (-not $a) { throw "no yq_windows_arm64.exe in yq release $($rel.tag_name)" }
      Invoke-WithRetry -What 'yq download' {
        Invoke-WebRequest $a.browser_download_url -OutFile (Join-Path $toolsDir 'yq.exe') -UseBasicParsing
      }
      $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
      if ($machPath -notlike "*$toolsDir*") {
        [Environment]::SetEnvironmentVariable('Path', $machPath.TrimEnd(';') + ';' + $toolsDir, 'Machine')
      }
      $packageProbes['jq-yq'] = @(
        @{ Dir = $toolsDir; File = 'jq.exe' },
        @{ Dir = $toolsDir; File = 'yq.exe' }
      )
    }
    default {
      # Unknown id: the app and this script drifted (or a hand-set env var).
      # Warn loudly but do not kill the build - the verification below only
      # gates on what actually has probes.
      Write-Warning "unknown package id '$pkg' - skipping (app/bootstrap catalog drift?)"
    }
  }
  # Immediate per-tool verification - fail at the tool that broke, not at the end.
  if ($packageProbes.ContainsKey($pkg)) {
    foreach ($p in $packageProbes[$pkg]) {
      $hit = Get-ChildItem -Path $p.Dir -Filter $p.File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $hit) { throw "package '$pkg': $($p.File) not found under $($p.Dir) after install" }
      Write-Host ("  verified {0}: {1}" -f $pkg, $hit.FullName)
    }
  }
}

# --- 1. win-arm64 actions-runner agent --------------------------------------
# Resolve the LATEST runner release at build time. The agent self-updates at job
# time anyway, so pinning buys nothing and only risks a 404 on a yanked/aged tag.
$ghHeaders = @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
# Retry through transient blips - this lookup is REQUIRED (no agent without it), so
# a momentary drop here must not fail the build.
$rel = Invoke-WithRetry -What 'actions-runner release lookup' {
  Invoke-RestMethod 'https://api.github.com/repos/actions/runner/releases/latest' -Headers $ghHeaders
}
$RunnerVersion = $rel.tag_name -replace '^v', ''            # 'v2.334.0' -> '2.334.0'
$assetName     = "actions-runner-win-arm64-$RunnerVersion.zip"
$asset         = $rel.assets | Where-Object { $_.name -eq $assetName }
if (-not $asset) {
  throw "No '$assetName' asset in actions-runner release $($rel.tag_name) - GitHub may have changed asset naming."
}

Write-Host "Installing actions-runner-win-arm64 v$RunnerVersion to $RunnerRoot ..."
New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
Set-Location $RunnerRoot

$zip = Join-Path $RunnerRoot 'runner.zip'
$url = $asset.browser_download_url

$attempt = 0
do {
  $attempt++
  try {
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -Headers $ghHeaders
    $len = (Get-Item $zip).Length
    if ($len -lt 20MB) {
      throw "runner.zip is only $len bytes from $url - not the agent archive (truncated/unexpected body)."
    }
    break
  } catch {
    if ($attempt -ge 5) { throw "failed to download runner.zip from $url after $attempt attempts: $_" }
    Start-Sleep -Seconds (5 * $attempt)   # linear backoff: 5s, 10s, 15s, 20s
  }
} while ($true)

Get-ChildItem -LiteralPath $RunnerRoot -Force |
  Where-Object { $_.Name -ne 'runner.zip' } |
  Remove-Item -Recurse -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $RunnerRoot)
} catch {
  $len = (Get-Item $zip -ErrorAction SilentlyContinue).Length
  throw "failed to extract runner.zip ($len bytes) from $url - not a valid zip (bad/partial download): $_"
}
Remove-Item $zip -Force

if (-not (Test-Path (Join-Path $RunnerRoot 'run.cmd'))) {
  throw "run.cmd not found in $RunnerRoot - runner extraction failed."
}

# --- 2. Per-job runtime: written at build time, runs on EVERY clone boot -----
$JobScript = 'C:\setup\run-job.ps1'
New-Item -ItemType Directory -Force -Path 'C:\setup' | Out-Null

# run-job.ps1 finds the per-clone JIT on the injected config disc, runs ONE job,
# then powers the VM off (the host's only completion signal). It ALSO powers off
# if no JIT is found after the full wait: the config disc is always pre-attached
# before the VM starts (no attach race on any backend), and leaving the VM up
# never self-heals (no re-scan, -AtLogOn task won't re-fire this session), so a
# fast power-off lets the host reclaim the slot and reconcile a fresh clone
# instead of stalling the full jobTimeout on a wedged guest.
@'
$ErrorActionPreference = "Continue"
$RunnerRoot = "C:\actions-runner"
$LogDir = "C:\setup\logs"; New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "run-job.log") -Append -Force | Out-Null

function Find-Jit {
  # Scan removable + CD-ROM volumes (DriveType 2,5) for the known per-clone file,
  # then fall back to every filesystem root and the MACTIONS-labeled volume.
  # Robust against drive-letter shuffle - mirrors autounattend.xml's bootstrap scan.
  $known = "mactions\jitconfig"
  $roots = @()
  $roots += (Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
             Where-Object { $_.DriveType -in 2, 5 } | ForEach-Object { $_.DeviceID })
  $roots += (Get-Volume -ErrorAction SilentlyContinue |
             Where-Object { $_.FileSystemLabel -eq "MACTIONS" -and $_.DriveLetter } |
             ForEach-Object { "$($_.DriveLetter):" })
  $roots += (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root
  foreach ($r in ($roots | Select-Object -Unique)) {
    $p = Join-Path ($r.TrimEnd("\") + "\") $known
    if (Test-Path $p) {
      # Guard the read: an empty/zero-byte jitconfig makes Get-Content -Raw return
      # $null in PS 5.1, and .Trim() on $null is a TERMINATING error that would
      # abort run-job.ps1 before EITHER shutdown branch runs - wedging the guest
      # powered-on for the full jobTimeout. Treat empty/whitespace (or a read
      # error) as "no JIT here" and keep scanning, so a broken config disc
      # degrades to the fast power-off path instead.
      try {
        $c = Get-Content -Raw -LiteralPath $p -ErrorAction Stop
        if ($c) { $t = $c.Trim(); if ($t) { return $t } }
      } catch { }
    }
  }
  return $null
}

# Wait briefly for the config disc (clone boot can beat the media attach).
$jit = $null
for ($i = 0; $i -lt 60 -and -not $jit; $i++) { $jit = Find-Jit; if (-not $jit) { Start-Sleep 2 } }

if ($jit) {
  Set-Location $RunnerRoot
  # run.cmd BLOCKS until the single JIT job completes, then exits (0 on a clean
  # ephemeral run). --jitconfig makes it single-use; no --once needed.
  & "$RunnerRoot\run.cmd" --jitconfig "$jit"
  Stop-Transcript | Out-Null
  # Self power-off - the host detects completion purely via VM power state.
  shutdown /s /t 0
} else {
  # No JIT after the full 120s wait. The config disc is wired to the clone's
  # sata0:0 CD BEFORE the VM starts (mactions-fusion-vm's clone verb), so a null
  # result here means a genuinely broken clone, NOT a transient attach race -
  # and leaving the VM up does NOT self-heal (this script never re-scans, and the
  # task is -AtLogOn only, so it won't re-fire within the same logged-on session).
  # Power off so the host's power-state poll reclaims the slot fast and the
  # orchestrator reconciles a fresh clone (with a fresh JIT) instead of burning
  # the full ~50-min jobTimeout on an idle guest while the JIT token expires.
  Write-Output "no jitconfig found on any removable/CD volume after wait; powering off so the host reclaims the slot"
  Stop-Transcript | Out-Null
  shutdown /s /t 0
}
'@ | Set-Content -Path $JobScript -Encoding UTF8

# Register the recurring autostart. ONLOGON for `runner` (already autologon'd by
# autounattend.xml), RunLevel Highest for a full token, no time limit so a long
# job isn't killed. A Scheduled Task beats RunOnce (self-deletes after one fire)
# and the Startup folder (racy, no RunLevel) for a per-clone runtime.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$JobScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User 'runner'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId 'runner' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'MactionsRunOnce' -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force | Out-Null

# --- 3. Disable UAC for the disposable guest --------------------------------
# `runner` is a local admin; with UAC on, the task could get a filtered token,
# breaking job steps that need admin. This guest is destroyed after one job.
# Reboot-gated - applied on the first clone boot for a job.
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name EnableLUA -Value 0

Write-Host ''
Write-Host '== Bootstrap complete. =='
Write-Host 'Per job, the host injects the JIT via a config disc; the runner registers'
Write-Host 'OUTBOUND, runs one job, and the VM powers itself off.'

# Verify the REQUIRED runner tools actually installed before we declare the base
# provisioned. The Git/7-Zip/pwsh installs above are best-effort (try/catch -> warn)
# so one transient download failure doesn't abort the whole ~hour build - but a
# SILENTLY-skipped git/bash/pwsh produces a base that snapshots "provisioned" yet
# can't run `actions/checkout` (falls back to a slow REST tarball), any `shell: bash`
# step ("bash: command not found"), or any `shell: pwsh` action. That exact silent
# failure shipped a broken base once. So gate the sentinel on the tools being present:
# if any REQUIRED one is missing, power off WITHOUT the sentinel and fusion-windows-base
# refuses to snapshot (fast, clear failure - re-run the build). 7-Zip stays optional.
# Literal paths (not $gitDir/$pwshDir - those are scoped inside the install try-blocks
# above and may be unset if a block threw before assigning them).
$required = [ordered]@{
  'git'  = 'C:\Git\cmd\git.exe'
  'bash' = 'C:\Git\bin\bash.exe'
  'pwsh' = (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
}
$missing = @()
foreach ($name in $required.Keys) {
  if (-not (Test-Path $required[$name])) { $missing += ("{0} ({1})" -f $name, $required[$name]) }
}
# The selected packages (sections 0b/0c) are fatal inline, so reaching here
# means they all installed - but re-verify anyway (belt-and-braces, same spirit
# as the literal paths above): a base missing something the user CHECKED would
# quietly lose exactly what they asked the rebuild for.
foreach ($id in $selectedToolcache) {
  $tc = $toolcacheCatalog[$id]
  $toolDir = Join-Path $ToolCacheDir $tc.Tool
  $markers = Get-ChildItem -Path $toolDir -Filter "$($tc.Arch).complete" -Recurse -ErrorAction SilentlyContinue
  if (-not $markers) { $missing += ("toolcache {0} (no {1}.complete markers under {2})" -f $id, $tc.Arch, $toolDir) }
}
foreach ($pkg in $packageProbes.Keys) {
  foreach ($p in $packageProbes[$pkg]) {
    $hit = Get-ChildItem -Path $p.Dir -Filter $p.File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) { $missing += ("package {0} ({1} under {2})" -f $pkg, $p.File, $p.Dir) }
  }
}
if ($missing.Count) {
  Write-Warning ("REQUIRED runner tools missing after provisioning: {0}. NOT writing the provisioning sentinel; powering off so the base build fails fast (a transient download failure is the usual cause - re-run the base build)." -f ($missing -join '; '))
  try { Stop-Transcript | Out-Null } catch { }
  shutdown /s /t 5 /c "Mactions base bootstrap FAILED: missing required tools (git/bash/pwsh or a selected package)"
  exit 1
}
Write-Host ("Verified required runner tools present: git, bash, pwsh{0}." -f $(
  if ($SelectedPackages.Count) { " + selected packages: " + ($SelectedPackages -join ', ') } else { '' }))

# Provisioning sentinel - written LAST, right before the orderly power-off.
# fusion-windows-base polls for this via VMware Tools guest-ops and ONLY
# snapshots the base if it appears, so a Setup/bootstrap failure that powers off
# can't be mistaken for a finished base. (run.cmd, run-job.ps1, the
# MactionsRunOnce task, and Tools are all in place by the time we reach here.)
try { Stop-Transcript | Out-Null } catch { }
New-Item -ItemType File -Force -Path (Join-Path $RunnerRoot '.mactions-provisioned') | Out-Null
# Auto-power-off so fusion-windows-base detects completion via guest shutdown
# (it polls `vmrun list`) without a human in the loop. The 60s delay lets the
# FirstLogonCommands wrapper mark Setup complete + flush post-FLC work before the
# VM goes down - and, with the host polling the sentinel every ~10s via guest-ops,
# leaves a wide enough window (~6 polls) that one slow/failed guest-ops call can't
# false-negative and make the host discard a genuinely-provisioned base.
shutdown /s /t 60 /c "Mactions base image bootstrap complete"
