<#
  bootstrap.ps1 - runs INSIDE the Windows 11 ARM guest on first logon
  (invoked once by autounattend.xml's FirstLogonCommands, at BUILD time).

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

$RunnerRoot = 'C:\actions-runner'

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
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline -and -not (Test-Outbound)) { Start-Sleep -Seconds 5 }
  if (-not (Test-Outbound)) {
    throw 'No outbound network after 180s. On VMware Fusion this means the vmxnet3 driver never bound (VMware Tools may need a reboot on this build); cannot download the runner agent.'
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
#
# Tools the runner agent itself bootstraps on demand (so we DON'T install):
#   - Node.js (actions/setup-node downloads the right version per .nvmrc)
#   - .NET (actions/setup-dotnet)
#   - Python (actions/setup-python)
#   - PowerShell 7 (Windows ships PS 5.1; actions request PS 7 via the action)
function Install-Msi {
  param([Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$LocalName)
  $tmp = Join-Path $env:TEMP $LocalName
  if (Test-Path $tmp) { Remove-Item $tmp -Force }
  Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
  $proc = Start-Process msiexec.exe -ArgumentList '/i', $tmp, '/quiet', '/norestart' -Wait -PassThru
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

# Git for Windows (ARM64) - use MinGit, a PLAIN .zip, NOT the Inno installer.
# The `Git-*-arm64.exe` Inno installer still pops a GUI under an unattended
# FirstLogonCommands session on ARM64 (its /VERYSILENT is honored on x64 but the
# ARM64 build surfaces a window with no desktop to click), which STALLS the base
# build. MinGit is Git-for-Windows' minimal redistributable (exactly what
# automation needs: git.exe under \cmd) and extracts with the same ZipFile path
# as the runner agent - zero installer UI possible. We add \cmd to the MACHINE
# PATH so actions/checkout (and the runner service) resolve `git`.
Write-Host 'Installing Git for Windows (ARM64, MinGit)...'
try {
  $gitRel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
    -Headers @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
  # Prefer the standard MinGit (skip the busybox variant for fewer surprises).
  $gitAsset = $gitRel.assets |
    Where-Object { $_.name -match '^MinGit-.*-arm64\.zip$' -and $_.name -notmatch 'busybox' } |
    Select-Object -First 1
  if (-not $gitAsset) {
    Write-Warning "No MinGit ARM64 asset in release $($gitRel.tag_name); skipping Git install."
  } else {
    $gitDir = 'C:\Git'
    $gitZip = Join-Path $env:TEMP 'mingit-arm64.zip'
    if (Test-Path $gitZip) { Remove-Item $gitZip -Force }
    Invoke-WebRequest -Uri $gitAsset.browser_download_url -OutFile $gitZip -UseBasicParsing
    if (Test-Path $gitDir) { Remove-Item $gitDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $gitDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($gitZip, $gitDir)
    Remove-Item $gitZip -Force
    $gitCmd = Join-Path $gitDir 'cmd'
    if (-not (Test-Path (Join-Path $gitCmd 'git.exe'))) {
      throw "git.exe not found under $gitCmd after MinGit extract"
    }
    $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machPath -notlike "*$gitCmd*") {
      [Environment]::SetEnvironmentVariable('Path', ($machPath.TrimEnd(';') + ';' + $gitCmd), 'Machine')
    }
    $env:Path = $env:Path + ';' + $gitCmd
    & "$gitCmd\git.exe" --version | Write-Host
  }
} catch {
  Write-Warning "Git install failed (continuing): $_"
}

# 7-Zip ARM64 - small, fast, useful for many actions. NOTE: 7-Zip ships NO
# ARM64 .msi (only x64) - the ARM64 build is an NSIS .exe that takes /S (NOT
# Inno's /VERYSILENT). There's no "latest" URL alias, so the version is pinned
# and must be bumped manually (check https://www.7-zip.org/download.html).
# Non-fatal: the try/catch lets the runner come up without it.
$SevenZipUrl = 'https://www.7-zip.org/a/7z2601-arm64.exe'   # MANUAL pin (no "latest" alias) — bump at https://www.7-zip.org/download.html
Write-Host 'Installing 7-Zip (ARM64)...'
try {
  Install-Exe -Url $SevenZipUrl -LocalName '7z-arm64.exe' -Args @('/S')
} catch {
  # Non-fatal: the runner comes up without 7-Zip. The pinned version can 404 once
  # 7-Zip ships a newer ARM64 build — say so explicitly so it's obvious the base
  # is missing 7-Zip (and which URL to bump) rather than a silent omission.
  Write-Warning "7-Zip install skipped (continuing without it): $SevenZipUrl failed - $_. If this is a 404, bump the pinned version in bootstrap.ps1."
}

# --- 1. win-arm64 actions-runner agent --------------------------------------
# Resolve the LATEST runner release at build time. The agent self-updates at job
# time anyway, so pinning buys nothing and only risks a 404 on a yanked/aged tag.
$ghHeaders = @{ 'User-Agent' = 'mactions'; 'Accept' = 'application/vnd.github+json' }
try {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/actions/runner/releases/latest' -Headers $ghHeaders
} catch {
  throw "Could not reach the GitHub releases API to resolve the actions-runner version: $($_.Exception.Message)"
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
    if ($attempt -ge 3) { throw "failed to download runner.zip from $url after $attempt attempts: $_" }
    Start-Sleep -Seconds (5 * $attempt)
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
# VM goes down — and, with the host polling the sentinel every ~10s via guest-ops,
# leaves a wide enough window (~6 polls) that one slow/failed guest-ops call can't
# false-negative and make the host discard a genuinely-provisioned base.
shutdown /s /t 60 /c "Mactions base image bootstrap complete"
