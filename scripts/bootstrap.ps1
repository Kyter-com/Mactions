<#
  bootstrap.ps1 — runs INSIDE the Windows 11 ARM guest on first logon
  (invoked by autounattend.xml's FirstLogonCommands).

  Turns a fresh Win11-ARM install into a Mactions runner base image:
    1. Enable OpenSSH Server (so the Mac host can SSH in to launch the agent),
       open the firewall, make cmd.exe the default SSH shell, and force password
       auth on (the host logs in as `runner` with a throwaway password).
    2. Resolve + download + extract the LATEST win-arm64 actions-runner agent to
       C:\actions-runner (short root path to dodge Windows MAX_PATH on deep
       node_modules trees).
    3. Disable UAC for this disposable guest so the SSH/cmd session runs with a
       full admin token.

  Mactions then drives the per-job loop from the host:
    clone base -> start -> ssh runner@<ip> "cd /d C:\actions-runner && run.cmd --jitconfig <JIT>"
  run.cmd with --jitconfig runs exactly ONE job then exits (and the ephemeral
  registration auto-deregisters from GitHub). The host force-stops + deletes the
  clone the instant SSH returns, so nothing survives the job.

  After this script finishes, SHUT THE VM DOWN and treat that powered-off VM as
  the pristine base image. Only throwaway clones of it are ever booted for jobs.
  (The first clone boot applies the EnableLUA=0 reboot-gated change.)

  Runs under in-box Windows PowerShell 5.1 (autounattend.xml calls `powershell`,
  not `pwsh`), so everything here is 5.1-compatible.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # PS 5.1 IWR progress bar throttles large -OutFile downloads ~10x
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RunnerRoot = 'C:\actions-runner'

Write-Host '== Mactions Windows base image bootstrap =='

# --- 1. OpenSSH Server ------------------------------------------------------
Write-Host 'Enabling OpenSSH Server...'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic

# Firewall: allow inbound TCP 22 (some images ship the rule, some don't).
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# Make cmd.exe the default shell for SSH sessions. The host launches the agent
# with `cd /d C:\actions-runner && run.cmd --jitconfig <JIT>` (see
# WindowsVMProvider.remoteCommand), which is CMD syntax: `&&` chaining and the
# `cd /d` drive-switch flag are BOTH PowerShell 5.1 parse errors, so the SSH
# DefaultShell MUST be cmd.exe for that command to run. (run.cmd is a batch file
# anyway.) If you ever switch DefaultShell to PowerShell, rewrite remoteCommand too.
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\cmd.exe' `
  -PropertyType String -Force | Out-Null

# The host logs in as `runner` with a password (sshpass), so password auth must
# be enabled. Win11's stock sshd_config also has a `Match Group administrators`
# block that redirects AuthorizedKeysFile to administrators_authorized_keys; for
# this throwaway guest password auth is all we need. (Long term: per-clone key
# auth — the provider already supports key auth when sshPassword is nil.)
$cfg = 'C:\ProgramData\ssh\sshd_config'
if (Test-Path $cfg) {
  $txt = Get-Content $cfg -Raw
  $txt = $txt -replace '(?m)^\s*#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication yes'
  if ($txt -notmatch '(?m)^\s*PasswordAuthentication\s+yes') {
    $txt = $txt.TrimEnd() + "`r`nPasswordAuthentication yes`r`n"
  }
  Set-Content -Path $cfg -Value $txt -Encoding ascii
}

# Start sshd AFTER DefaultShell + sshd_config are written, then Restart to be
# certain the daemon read the final config.
Start-Service sshd
Restart-Service sshd

# --- 2. win-arm64 actions-runner agent --------------------------------------
# Resolve the LATEST runner release at build time. The agent self-updates at job
# time anyway, so pinning buys nothing and only risks a 404 on a yanked/aged tag.
# Mirrors the macOS path in RunnerInstaller.swift (always-latest).
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
  throw "No '$assetName' asset in actions-runner release $($rel.tag_name) — GitHub may have changed asset naming."
}

Write-Host "Installing actions-runner-win-arm64 v$RunnerVersion to $RunnerRoot ..."
New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
Set-Location $RunnerRoot

$zip = Join-Path $RunnerRoot 'runner.zip'
$url = $asset.browser_download_url

# Download with bounded retries (one-shot first-logon run — survive a transient
# drop), and verify it's really the ~tens-of-MB archive, not an interstitial or
# truncated body.
$attempt = 0
do {
  $attempt++
  try {
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -Headers $ghHeaders
    $len = (Get-Item $zip).Length
    if ($len -lt 20MB) {
      throw "runner.zip is only $len bytes from $url — not the agent archive (truncated/unexpected body)."
    }
    break
  } catch {
    if ($attempt -ge 3) { throw "failed to download runner.zip from $url after $attempt attempts: $_" }
    Start-Sleep -Seconds (5 * $attempt)
  }
} while ($true)

# Idempotency: wipe any prior extraction (keep the freshly downloaded zip) so a
# re-run / version bump doesn't trip ExtractToDirectory's "file already exists".
Get-ChildItem -LiteralPath $RunnerRoot -Force |
  Where-Object { $_.Name -ne 'runner.zip' } |
  Remove-Item -Recurse -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $RunnerRoot)
} catch {
  $len = (Get-Item $zip -ErrorAction SilentlyContinue).Length
  throw "failed to extract runner.zip ($len bytes) from $url — not a valid zip (bad/partial download): $_"
}
Remove-Item $zip -Force

# Sanity: confirm the win-arm64 agent landed.
if (-not (Test-Path (Join-Path $RunnerRoot 'run.cmd'))) {
  throw "run.cmd not found in $RunnerRoot — runner extraction failed."
}

# --- 3. Disable UAC for the disposable guest --------------------------------
# `runner` is a local admin; with UAC on, an SSH/cmd session gets a filtered
# (non-elevated) token, which can break job steps needing admin (tool installs,
# writes outside the profile). This guest is destroyed after one job, so drop the
# admin-token split. Reboot-gated — applied on the first clone boot for a job.
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name EnableLUA -Value 0

Write-Host ''
Write-Host '== Bootstrap complete. =='
Write-Host 'Now SHUT THIS VM DOWN; the powered-off VM is your pristine base image.'
Write-Host 'Verify arch in a job with:  echo $env:RUNNER_ARCH  ->  expect ARM64'
