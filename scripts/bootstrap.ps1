<#
  bootstrap.ps1 — runs INSIDE the Windows 11 ARM guest on first logon
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
  registration (Parallels attaches it; UTM overwrites a fixed in-bundle drive),
  and boots the clone headless. run-job.ps1 then:
    - finds the JIT on the config disc (by volume label / drive scan),
    - runs `run.cmd --jitconfig <JIT>` for exactly ONE job (registers OUTBOUND to
      GitHub, auto-deregisters when done),
    - powers the VM off. The host detects completion purely by polling VM power
      state, then deletes the clone. Nothing inbound, nothing left behind.

  After this script finishes, SHUT THE VM DOWN — the powered-off VM is the
  pristine base image. (The first clone boot applies the EnableLUA=0 reboot-gated
  change.) Runs under in-box Windows PowerShell 5.1, so everything here is
  5.1-compatible.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # PS 5.1 IWR progress bar throttles large -OutFile downloads ~10x
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RunnerRoot = 'C:\actions-runner'

Write-Host '== Mactions Windows base image bootstrap (outbound/headless) =='

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
  throw "No '$assetName' asset in actions-runner release $($rel.tag_name) — GitHub may have changed asset naming."
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
      throw "runner.zip is only $len bytes from $url — not the agent archive (truncated/unexpected body)."
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
  throw "failed to extract runner.zip ($len bytes) from $url — not a valid zip (bad/partial download): $_"
}
Remove-Item $zip -Force

if (-not (Test-Path (Join-Path $RunnerRoot 'run.cmd'))) {
  throw "run.cmd not found in $RunnerRoot — runner extraction failed."
}

# --- 2. Per-job runtime: written at build time, runs on EVERY clone boot -----
$JobScript = 'C:\setup\run-job.ps1'
New-Item -ItemType Directory -Force -Path 'C:\setup' | Out-Null

# run-job.ps1 finds the per-clone JIT on the injected config disc, runs ONE job,
# then powers the VM off (the host's only completion signal). NOTE: it must NOT
# power off when no JIT is found — a media-attach race should self-heal, not look
# like a completed job to the host's power-state poll.
@'
$ErrorActionPreference = "Continue"
$RunnerRoot = "C:\actions-runner"
$LogDir = "C:\setup\logs"; New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "run-job.log") -Append -Force | Out-Null

function Find-Jit {
  # Scan removable + CD-ROM volumes (DriveType 2,5) for the known per-clone file,
  # then fall back to every filesystem root and the MACTIONS-labeled volume.
  # Robust against drive-letter shuffle — mirrors autounattend.xml's bootstrap scan.
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
    if (Test-Path $p) { return (Get-Content -Raw -LiteralPath $p).Trim() }
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
  # Self power-off — the host detects completion purely via VM power state.
  shutdown /s /t 0
} else {
  # No JIT yet: do NOT power off (a media race would look like a finished job to
  # the host). Leave the VM up; the host's jobTimeout + force-kill is the backstop.
  Write-Output "no jitconfig found on any removable/CD volume after wait; leaving VM up"
  Stop-Transcript | Out-Null
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
# Reboot-gated — applied on the first clone boot for a job.
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name EnableLUA -Value 0

Write-Host ''
Write-Host '== Bootstrap complete. =='
Write-Host 'Now SHUT THIS VM DOWN; the powered-off VM is your pristine base image.'
Write-Host 'Per job, the host injects the JIT via a config disc; the runner registers'
Write-Host 'OUTBOUND, runs one job, and the VM powers itself off.'
