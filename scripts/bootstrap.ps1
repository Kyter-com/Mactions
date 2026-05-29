<#
  bootstrap.ps1 — runs INSIDE the Windows 11 ARM guest on first logon
  (invoked by autounattend.xml's FirstLogonCommands).

  Turns a fresh Win11-ARM install into a Mactions runner base image:
    1. Enable OpenSSH Server (so the Mac host can SSH in to launch the agent),
       open the firewall, and make PowerShell the default SSH shell.
    2. Download + extract the win-arm64 actions-runner agent to C:\actions-runner
       (short root path to dodge Windows MAX_PATH on deep node_modules trees).

  Mactions then drives the per-job loop from the host:
    clone base -> start -> ssh runner@<ip> "cd /d C:\actions-runner && run.cmd --jitconfig <JIT>"
  run.cmd with --jitconfig runs exactly ONE job then exits (and the ephemeral
  registration auto-deregisters from GitHub). The host force-stops + deletes the
  clone the instant SSH returns, so nothing survives the job.

  After this script finishes, SHUT THE VM DOWN and treat that powered-off VM as
  the pristine base image. Only throwaway clones of it are ever booted for jobs.

  NOTE: pin RUNNER_VERSION to a real release tag from
  https://github.com/actions/runner/releases (asset actions-runner-win-arm64-<ver>.zip).
#>

$ErrorActionPreference = 'Stop'
$RunnerVersion = '2.334.0'   # update to the latest win-arm64 release as needed
$RunnerRoot    = 'C:\actions-runner'

Write-Host '== Mactions Windows base image bootstrap =='

# --- 1. OpenSSH Server ------------------------------------------------------
Write-Host 'Enabling OpenSSH Server...'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# Firewall: allow inbound TCP 22 (some images ship the rule, some don't).
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# Make PowerShell the default shell for SSH sessions so the remote command runs
# in a real shell (the runner's run.cmd is a batch file; cmd works too, but
# PowerShell is the documented default-shell choice).
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force | Out-Null

# --- 2. win-arm64 actions-runner agent --------------------------------------
Write-Host "Installing actions-runner-win-arm64 v$RunnerVersion to $RunnerRoot ..."
New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
Set-Location $RunnerRoot

$zip = Join-Path $RunnerRoot 'runner.zip'
$url = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-arm64-$RunnerVersion.zip"
Invoke-WebRequest -Uri $url -OutFile $zip
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $RunnerRoot)
Remove-Item $zip -Force

# Sanity: confirm the win-arm64 agent landed and Node will be native arm64.
if (-not (Test-Path (Join-Path $RunnerRoot 'run.cmd'))) {
  throw "run.cmd not found in $RunnerRoot — runner extraction failed."
}

Write-Host ''
Write-Host '== Bootstrap complete. =='
Write-Host 'Now SHUT THIS VM DOWN; the powered-off VM is your pristine base image.'
Write-Host 'Verify arch in a job with:  echo $env:RUNNER_ARCH  ->  expect ARM64'
