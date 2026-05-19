$hasErrors = $false

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

$autotunerModule = Join-Path $utilsDir "autotuner.psm1"
if (Test-Path $autotunerModule) { Import-Module $autotunerModule -Force }
$telemetryFile = Join-Path $resultsDir "autotuner_telemetry.jsonl"
$stateTableFile = Join-Path $utilsDir "destination-state-table.json"
$reasonCodeFile = Join-Path $utilsDir "runtime-selection-reasons.txt"
$ipsetStageDir = Join-Path $listsDir "ipset-stage"
$ipsetCandidateFile = Join-Path $ipsetStageDir "candidate.txt"
$ipsetProbationFile = Join-Path $ipsetStageDir "probation.txt"
$ipsetStableFile = Join-Path $ipsetStageDir "stable.txt"
$ipsetExcludeFile = Join-Path $listsDir "ipset-exclude-user.txt"
$degradationFile = Join-Path $utilsDir "degradation-thresholds.conf"
$realtimeSafeFlag = Join-Path $utilsDir "realtime_safe.enabled"


# Define functions early
function Get-IpsetStatus {
    $listFile = Join-Path $listsDir "ipset-all.txt"
    if (-not (Test-Path $listFile)) { return "none" }
    $lineCount = (Get-Content $listFile | Measure-Object -Line).Lines
    if ($lineCount -eq 0) { return "any" }
    $hasDummy = Get-Content $listFile | Select-String -Pattern "203\.0\.113\.113/32" -Quiet
    if ($hasDummy) { return "none" } else { return "loaded" }
}

function Set-IpsetMode {
    param([string]$mode)
    $listFile = Join-Path $listsDir "ipset-all.txt"
    $backupFile = Join-Path $listsDir "ipset-all.test-backup.txt"
    if ($mode -eq "any") {
        # Always backup current file (even if none)
        if (Test-Path $listFile) {
            Copy-Item $listFile $backupFile -Force
        } else {
            # If none, create empty backup
            "" | Out-File $backupFile -Encoding UTF8
        }
        # Make file empty
        "" | Out-File $listFile -Encoding UTF8
    } elseif ($mode -eq "restore") {
        if (Test-Path $backupFile) {
            Move-Item $backupFile $listFile -Force
        }
    }
}

trap {
    Write-Host "[ERROR] Script interrupted. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
    break
}

function New-OrderedDict { New-Object System.Collections.Specialized.OrderedDictionary }
function Get-DegradationThresholds {
    $defaults = @{ MAX_JITTER_MS = 45.0; MAX_TIMEOUT_RATIO = 0.25; MAX_FAILED_PROBES = 3 }
    if (-not (Test-Path $degradationFile)) { return $defaults }
    foreach ($line in Get-Content $degradationFile) {
        if ($line -match '^\s*([^=]+)=(.+)\s*$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim()
            if ($k -eq 'MAX_JITTER_MS') { $defaults.MAX_JITTER_MS = [double]$v }
            if ($k -eq 'MAX_TIMEOUT_RATIO') { $defaults.MAX_TIMEOUT_RATIO = [double]$v }
            if ($k -eq 'MAX_FAILED_PROBES') { $defaults.MAX_FAILED_PROBES = [int]$v }
        }
    }
    return $defaults
}
function Add-OrSet {
    param($dict, $key, $val)
    if ($dict.Contains($key)) { $dict[$key] = $val } else { $dict.Add($key, $val) }
}
function Load-StateTable {
    if (-not (Test-Path $stateTableFile)) { return @{} }
    try {
        $raw = Get-Content $stateTableFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $raw) { return @{} }
        return $raw
    } catch { return @{} }
}
function Save-StateTable { param([hashtable]$Table) ($Table | ConvertTo-Json -Depth 8) | Out-File $stateTableFile -Encoding UTF8 }
function Ensure-IpsetStageFiles {
    if (-not (Test-Path $ipsetStageDir)) { New-Item -ItemType Directory -Path $ipsetStageDir | Out-Null }
    foreach ($f in @($ipsetCandidateFile,$ipsetProbationFile,$ipsetStableFile)) { if (-not (Test-Path $f)) { "" | Out-File $f -Encoding UTF8 } }
}
function Update-StagedIpset {
    param([string]$Host,[double]$SuccessRate)
    Ensure-IpsetStageFiles
    $c = @(Get-Content $ipsetCandidateFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -ne $Host })
    $p = @(Get-Content $ipsetProbationFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -ne $Host })
    $s = @(Get-Content $ipsetStableFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -ne $Host })
    if ($SuccessRate -ge 0.9) { $s += $Host }
    elseif ($SuccessRate -ge 0.5) { $p += $Host }
    else { $c += $Host }
    $c | Set-Content $ipsetCandidateFile
    $p | Set-Content $ipsetProbationFile
    $s | Set-Content $ipsetStableFile
    ($s | Sort-Object -Unique) | Set-Content (Join-Path $listsDir "ipset-all.txt")
}

# Convert raw target value to structured target (supports PING:ip for ping-only targets)
function Convert-Target {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -like "PING:*") {
        $ping = $Value -replace '^PING:\s*', ''
        $url = $null
        $pingTarget = $ping
    } else {
        $url = $Value
        $pingTarget = $url -replace "^https?://", "" -replace "/.*$", ""
    }

    return (New-Object PSObject -Property @{
        Name       = $Name
        Url        = $url
        PingTarget = $pingTarget
    })
}

# DPI checker defaults (override via MONITOR_* env vars like in monitor.ps1)
$dpiTimeoutSeconds = 5
$dpiRangeBytes = 65536
$dpiMaxParallel = 8
$dpiCustomHost = $env:MONITOR_HOST
if ($env:MONITOR_TIMEOUT) { [int]$dpiTimeoutSeconds = $env:MONITOR_TIMEOUT }
if ($env:MONITOR_RANGE) { [int]$dpiRangeBytes = $env:MONITOR_RANGE }
if ($env:MONITOR_MAX_PARALLEL) { [int]$dpiMaxParallel = $env:MONITOR_MAX_PARALLEL }

function Get-DpiSuite {
    # Suite sourced from https://github.com/hyperion-cs/dpi-checkers (Apache-2.0 license)
    # Original copyright retained from dpi-checkers repository
    $url = "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"

    try {
        (Invoke-RestMethod -Uri $url -TimeoutSec $dpiTimeoutSeconds) |
            Select-Object `
                @{n='Id';       e={$_.id}},
                @{n='Provider'; e={$_.provider}},
                @{n='Country';  e={$_.country}},
                @{n='Host';     e={$_.host}}
    }
    catch {
        Write-Host "[WARN] Fetch dpi suite failed." -ForegroundColor Yellow
        @()
    }
}

function Build-DpiTargets {
    param(
        [string]$CustomHost
    )

    $suite = Get-DpiSuite
    $targets = @()

    if ($CustomHost) {
        $targets += @{ Id = "CUSTOM"; Provider = "Custom"; Country = "💡"; Host = $CustomHost }
    } else {
        foreach ($entry in $suite) {
            $targets += @{ Id = $entry.Id; Country = $entry.Country; Provider = $entry.Provider; Host = $entry.Host }
        }
    }

    return $targets
}

function Invoke-DpiSuite {
    param(
        [array]$Targets,
        [int]$TimeoutSeconds,
        [int]$RangeBytes,
        [int]$MaxParallel
    )

    $tests = @(
        @{ Label = "HTTP";   Args = @("--http1.1") },
        @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
        @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
    )

    $rangeSpec = "0-$($RangeBytes - 1)"
    $warnDetected = $false

    Write-Host "[INFO] Targets: $($Targets.Count) (custom URL overrides suite). Range: $rangeSpec bytes; Timeout: $($TimeoutSeconds)s" -ForegroundColor Cyan
    Write-Host "[INFO] Starting DPI TCP 16-20 checks (parallel: $MaxParallel)..." -ForegroundColor DarkGray

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()

    $payload = New-Object byte[] $RangeBytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($payload)

    $payloadFile = New-TemporaryFile
    [IO.File]::WriteAllBytes($payloadFile, $payload)

    $scriptBlock = {
        param($payloadFile, $target, $tests, $rangeSpec, $TimeoutSeconds)

        $warned = $false
        $lines = @()

        foreach ($test in $tests) {
            $curlArgs = @(
                "--range", $rangeSpec,
                "-m", $TimeoutSeconds,
                "-w", "%{http_code} %{size_upload} %{size_download} %{time_total}",
                "-o", "NUL",
                "-X", "POST",
                "--data-binary", "@$payloadFile",
                "-s"
            ) + $test.Args + @("https://$($target.Host)")

            $output = $payload | curl.exe @curlArgs 2>&1
            $exit = $LASTEXITCODE
            $text = ($output | Out-String).Trim()

            $code = "NA"
            $upBytes = 0
            $downBytes = 0
            $time = -1

            if ($text -match '^(?<code>\d{3})\s+(?<up>\d+)\s+(?<down>\d+)\s+(?<time>[\d\.]+)$') {
                $code = $matches['code']
                $upBytes = [int64]$matches['up']
                $downBytes = [int64]$matches['down']
                $time = [double]$matches['time']
            } elseif (($exit -eq 35) -or ($text -match "not supported|does not support|protocol\s+'.+'\s+not\s+supported|protocol\s+.+\s+not\s+supported|unsupported protocol|TLS.not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel|SSL")) {
                $code = "UNSUP"
            } elseif ($text) {
                $code = "ERR"
            }

            $upKB = [math]::Round($upBytes / 1024, 1)
            $downKB = [math]::Round($downBytes / 1024, 1)
            $status = "OK"
            $color = "Green"

            if ($code -eq "UNSUP") {
                $status = "UNSUPPORTED"
                $color = "Yellow"
            } elseif ($exit -ne 0 -or $code -eq "ERR" -or $code -eq "NA") {
                $status = "FAIL"
                $color = "Red"
            }

            if (($upBytes -gt 0) -and ($downBytes -eq 0) -and ($time -ge $TimeoutSeconds) -and ($exit -ne 0)) {
                $status = "LIKELY_BLOCKED"
                $color = "Yellow"
                $warned = $true
            }

            $lines += [PSCustomObject]@{
                TestLabel = $test.Label
                Code      = $code
                UpBytes   = $upBytes
                UpKB      = $upKB
                DownBytes = $downBytes
                DownKB    = $downKB
                Time      = $time
                Status    = $status
                Color     = $color
                Warned    = $warned
            }
        }

        return [PSCustomObject]@{
            TargetId = $target.Id
            Provider = $target.Provider
            Country   = $target.Country
            Lines    = $lines
            Warned   = $warned
        }
    }

    $runspaces = @()
    foreach ($target in $Targets) {
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        [void]$powershell.AddArgument($payloadFile)
        [void]$powershell.AddArgument($target)
        [void]$powershell.AddArgument($tests)
        [void]$powershell.AddArgument($rangeSpec)
        [void]$powershell.AddArgument($TimeoutSeconds)
        $powershell.RunspacePool = $runspacePool

        $runspaces += [PSCustomObject]@{
            Powershell = $powershell
            Handle     = $powershell.BeginInvoke()
            TargetId   = $target.Id
        }
    }

    $results = @()
    foreach ($rs in $runspaces) {
        # Wait for the runspace to complete with a small grace period beyond curl's timeout
        try {
            $waitMs = ([int]$TimeoutSeconds + 5) * 1000
            $handle = $rs.Handle
            if ($handle -and $handle.AsyncWaitHandle) {
                $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                if (-not $completed) {
                    Write-Host "[WARN] Runspace for [$($rs.TargetId)] timed out after $waitMs ms; stopping runspace..." -ForegroundColor Yellow
                    try { $rs.Powershell.Stop() } catch {}
                }
            }
        } catch {
            # ignore wait errors and attempt to EndInvoke
        }

        try {
            $res = $rs.Powershell.EndInvoke($rs.Handle)
            $results += $res

            Write-Host "`n=== [$($res.Country)][$($res.Provider)] $($res.TargetId) ===" -ForegroundColor DarkCyan
            foreach ($line in $res.Lines) {
                $msg = "[{0}] code={1} buf_up={2} bytes ({3} KB) buf_down={4} bytes ({5} KB) time={6}s status={7}" -f $line.TestLabel, $line.Code, $line.UpBytes, $line.UpKB, $line.DownBytes, $line.DownKB, $line.Time, $line.Status
                Write-Host $msg -ForegroundColor $line.Color
                if ($line.Status -eq "LIKELY_BLOCKED") {
                    Write-Host "  Pattern matches 16-20KB freeze; censor likely cutting this strategy." -ForegroundColor Yellow
                }
            }

            if ($res.Warned) {
                $warnDetected = $true
            } else {
                Write-Host "  No 16-20KB freeze pattern for this target." -ForegroundColor Green
            }
        } catch {
            Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
            $failedLine = [PSCustomObject]@{
                TestLabel  = 'RUNSPACE'
                Code       = 'ERR'
                SizeBytes  = 0
                SizeKB     = 0
                Status     = 'FAIL'
                Color      = 'Red'
                Warned     = $false
            }
            $results += [PSCustomObject]@{ TargetId = 'UNKNOWN'; Provider = 'UNKNOWN'; Lines = @($failedLine); Warned = $false }
        }
        $rs.Powershell.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()

    if ($warnDetected) {
        Write-Host ""
        Write-Host "[WARNING] Detected possible DPI TCP 16-20 blocking on one or more targets. Consider changing strategy/SNI/IP." -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "[OK] No 16-20KB freeze pattern detected across targets." -ForegroundColor Green
    }

    return $results
}

function Test-ZapretServiceConflict {
    return [bool](Get-Service -Name "zapret" -ErrorAction SilentlyContinue)
}

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Run as Administrator to execute tests" -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host "[OK] Administrator rights detected" -ForegroundColor Green
}

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] curl.exe not found" -ForegroundColor Red
    Write-Host "Install curl or add it to PATH" -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host "[OK] curl.exe found" -ForegroundColor Green
}

# Check for leftover ipset flag from previous interrupted run
$ipsetFlagFile = Join-Path $rootDir "ipset_switched.flag"
if (Test-Path $ipsetFlagFile) {
    Write-Host "[INFO] Detected leftover ipset switch flag. Restoring ipset..." -ForegroundColor Yellow
    Set-IpsetMode -mode "restore"
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

# Get original ipset status early
$originalIpsetStatus = Get-IpsetStatus

# Warn about ipset switching and X button behavior
if ($originalIpsetStatus -ne "any") {
    Write-Host "[INFO] Current ipset status: $originalIpsetStatus" -ForegroundColor Cyan
    Write-Host "[WARNING] Ipset will be switched to 'any' for accurate DPI tests." -ForegroundColor Yellow
    Write-Host "[WARNING] If you close the window with the X button, ipset will NOT restore immediately." -ForegroundColor Yellow
    Write-Host "[WARNING] It will be restored automatically on the next script run." -ForegroundColor Yellow
}

# Check if zapret service installed
if (Test-ZapretServiceConflict) {
    Write-Host "[ERROR] Windows service 'zapret' is installed" -ForegroundColor Red
    Write-Host "         Remove the service before running tests" -ForegroundColor Yellow
    Write-Host "         Open service.bat and choose 'Remove Services'" -ForegroundColor Yellow
    $hasErrors = $true
}

if ($hasErrors) {
    Write-Host ""
    Write-Host "Fix the errors above and rerun." -ForegroundColor Yellow
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

$dpiTargets = Build-DpiTargets -CustomHost $dpiCustomHost

# Config
$targetDir = $rootDir
if (-not $targetDir) { $targetDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$batFiles = Get-ChildItem -Path $targetDir -Filter "*.bat" | Where-Object { $_.Name -notlike "service*" } | Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }

$globalResults = @()

# Select top-level test type (standard vs DPI checkers)
function Read-TestType {
    while ($true) {
        Write-Host ""
        Write-Host "Select test type:" -ForegroundColor Cyan
        Write-Host "  [1] Standard tests (HTTP/ping)" -ForegroundColor Gray
        Write-Host "  [2] DPI checkers (TCP 16-20 freeze)" -ForegroundColor Gray
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice) {
            '1' { return 'standard' }
            '2' { return 'dpi' }
            default { Write-Host "Incorrect input. Please try again." -ForegroundColor Yellow }
        }
    }
}

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        Write-Host ""
        Write-Host "Select test run mode:" -ForegroundColor Cyan
        Write-Host "  [1] All configs" -ForegroundColor Gray
        Write-Host "  [2] Selected configs" -ForegroundColor Gray
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice) {
            '1' { return 'all' }
            '2' { return 'select' }
            default { Write-Host "Incorrect input. Please try again." -ForegroundColor Yellow }
        }
    }
}

function Read-ConfigSelection {
    param([array]$allFiles)

    while ($true) {
        Write-Host "" 
        Write-Host "Available configs:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allFiles.Count; $i++) {
            $idx = $i + 1
            Write-Host "  [$idx] $($allFiles[$i].Name)" -ForegroundColor Gray
        }

        $selectionInput = Read-Host "Enter numbers (e.g. 1,3,5) , ranges (e.g. 2-7), or mixed (e.g. 1,5-10,12). '0' for all"
        $trimmed = $selectionInput.Trim()
        
        if ($trimmed -eq '0') {
            return $allFiles
        }

        $parts = $selectionInput -split '[,\s]+' | Where-Object { $_ -match '^\d+(-\d+)?$' }
        if ($parts.Count -eq 0) {
            Write-Host ""
            Write-Host "Invalid input format. Use numbers, ranges (1-5), or combinations (1,3-7,10). Try again." -ForegroundColor Yellow
            continue
        }
        $selectedIndices = @()
        $hasErrors = $false
        
        foreach ($part in $parts) {
            if ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$matches[1]
                $end = [int]$matches[2]
                
                if ($start -gt $end) {
                    Write-Host "  [WARN] Invalid range '$part' (start > end). Skipping." -ForegroundColor Yellow
                    $hasErrors = $true
                    continue
                }
                
                if ($start -lt 1 -or $end -gt $allFiles.Count) {
                    Write-Host "  [WARN] Range '$part' out of bounds (valid: 1-$($allFiles.Count)). Skipping invalid parts." -ForegroundColor Yellow
                    $hasErrors = $true
                    $start = [Math]::Max($start, 1)
                    $end = [Math]::Min($end, $allFiles.Count)
                }
                
                for ($i = $start; $i -le $end; $i++) {
                    $selectedIndices += $i
                }
            } else {
                $num = [int]$part
                if ($num -ge 1 -and $num -le $allFiles.Count) {
                    $selectedIndices += $num
                } else {
                    Write-Host "  [WARN] Number '$num' out of bounds (valid: 1-$($allFiles.Count)). Skipping." -ForegroundColor Yellow
                    $hasErrors = $true
                }
            }
        }
        $valid = $selectedIndices | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count }
        if ($valid.Count -eq 0) {
            Write-Host ""
            Write-Host "No valid configs selected. Try again." -ForegroundColor Yellow
            continue
        }

        # Checker
         Write-Host "Selected configs: $($valid -join ', ')" -ForegroundColor Green
        if ($hasErrors) {
            Write-Host "Some entries were skipped due to errors (see warnings above)." -ForegroundColor Yellow
        }
        
        return $valid | ForEach-Object { $allFiles[$_ - 1] }
    }
}

while ($true) {
    $globalResults = @()
$testType = Read-TestType
$mode = Read-ModeSelection
if ($mode -eq 'select') {
    $selected = Read-ConfigSelection -allFiles $batFiles
    $batFiles = @($selected)
}

# Load targets once for standard mode
$targetList = @()
$maxNameLen = 10
if ($testType -eq 'standard') {
    $targetsFile = Join-Path $utilsDir "targets.txt"
    $rawTargets = New-OrderedDict
    if (Test-Path $targetsFile) {
        Get-Content $targetsFile | ForEach-Object {
            if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
                Add-OrSet -dict $rawTargets -key $matches[1] -val $matches[2]
            }
        }
    }

    if ($rawTargets.Count -eq 0) {
        Write-Host "[INFO] targets.txt missing or empty. Using defaults." -ForegroundColor Gray
        Add-OrSet $rawTargets "Discord Main"           "https://discord.com"
        Add-OrSet $rawTargets "Discord Gateway"        "https://gateway.discord.gg"
        Add-OrSet $rawTargets "Discord CDN"            "https://cdn.discordapp.com"
        Add-OrSet $rawTargets "Discord Updates"        "https://updates.discord.com"
        Add-OrSet $rawTargets "YouTube Web"            "https://www.youtube.com"
        Add-OrSet $rawTargets "YouTube Short"          "https://youtu.be"
        Add-OrSet $rawTargets "YouTube Image"          "https://i.ytimg.com"
        Add-OrSet $rawTargets "YouTube Video Redirect" "https://redirector.googlevideo.com"
        Add-OrSet $rawTargets "Google Main"            "https://www.google.com"
        Add-OrSet $rawTargets "Google Gstatic"         "https://www.gstatic.com"
        Add-OrSet $rawTargets "Cloudflare Web"         "https://www.cloudflare.com"
        Add-OrSet $rawTargets "Cloudflare CDN"         "https://cdnjs.cloudflare.com"
        Add-OrSet $rawTargets "Cloudflare DNS 1.1.1.1" "PING:1.1.1.1"
        Add-OrSet $rawTargets "Cloudflare DNS 1.0.0.1" "PING:1.0.0.1"
        Add-OrSet $rawTargets "Google DNS 8.8.8.8"     "PING:8.8.8.8"
        Add-OrSet $rawTargets "Google DNS 8.8.4.4"     "PING:8.8.4.4"
        Add-OrSet $rawTargets "Quad9 DNS 9.9.9.9"      "PING:9.9.9.9"
    } else {
        Write-Host ""
        Write-Host "[INFO] Loaded targets from targets.txt" -ForegroundColor Gray
        Write-Host "[INFO] Targets loaded: $($rawTargets.Count)" -ForegroundColor Gray
    }

    foreach ($key in $rawTargets.Keys) {
        $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
    }

    $targetUrlMap = @{}
    foreach ($target in $targetList) { $targetUrlMap[$target.Name] = $target.Url }

    $maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }
}

# Ensure we have configs to run
if (-not $batFiles -or $batFiles.Count -eq 0) {
    Write-Host "[ERROR] No general*.bat files found" -ForegroundColor Red
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Capture/restore running winws instances to return user ipset/config
function Get-WinwsSnapshot {
    try {
        return Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
            Select-Object ProcessId, CommandLine, ExecutablePath
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    param($snapshot)

    if (-not $snapshot -or $snapshot.Count -eq 0) { return }

    $current = @()
    try { $current = (Get-WinwsSnapshot).CommandLine } catch { $current = @() }

    Write-Host "[INFO] Restoring previously running winws instances..." -ForegroundColor DarkGray
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath) { continue }

        # Skip if an identical command line is already active
        if ($current -and $current -contains $p.CommandLine) { continue }

        $exe = $p.ExecutablePath
        $processArgs = ""
        if ($p.CommandLine) {
            $quotedExe = '"' + $exe + '"'
            if ($p.CommandLine.StartsWith($quotedExe)) {
                $processArgs = $p.CommandLine.Substring($quotedExe.Length).Trim()
            } elseif ($p.CommandLine.StartsWith($exe)) {
                $processArgs = $p.CommandLine.Substring($exe.Length).Trim()
            }
        }

        Start-Process -FilePath $exe -ArgumentList $processArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
    }
}

$env:NO_UPDATE_CHECK = "1"
$originalWinws = Get-WinwsSnapshot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 ZAPRET CONFIG TESTS" -ForegroundColor Cyan
Write-Host "                 Mode: $($testType.ToUpper())" -ForegroundColor Cyan
Write-Host "                 Total configs: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

try {
    # Save original ipset status and switch to 'any' for accurate DPI tests
    if (($originalIpsetStatus -ne "any") -and ($testType -eq 'dpi')) {
        Write-Host "[WARNING] Ipset is in '$originalIpsetStatus' mode. Switching to 'any' for accurate DPI tests..." -ForegroundColor Yellow
        Set-IpsetMode -mode "any"
        # Create flag file to indicate ipset was switched
        "" | Out-File -FilePath $ipsetFlagFile -Encoding UTF8
    }
    Write-Host "[WARNING] Tests may take several minutes to complete. Please wait..." -ForegroundColor Yellow

    $configNum = 0
    foreach ($file in $batFiles) {
    $configNum++
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [$configNum/$($batFiles.Count)] $($file.Name)" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    
    # Cleanup
    Stop-Zapret
    
    # Start config
    Write-Host "  > Starting config..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $targetDir -PassThru -WindowStyle Minimized
    
    # Wait init
    Start-Sleep -Seconds 5
    
    if ($testType -eq 'standard') {
        $curlTimeoutSeconds = 5

        # Parallel target checks via runspace pool (faster than jobs)
        $maxParallel = 8
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
        $runspacePool.Open()

        $scriptBlock = {
            param($t, $curlTimeoutSeconds)

            $httpPieces = @()

            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
                    @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
                    @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
                )

                $baseArgs = @("-I", "-s", "-m", $curlTimeoutSeconds, "-o", "NUL", "-w", "%{http_code}", "--show-error")
                foreach ($test in $tests) {
                    try {
                        $curlArgs = $baseArgs + $test.Args
                        $stderr = $null
                        $output = & curl.exe @curlArgs $t.Url 2>&1 | ForEach-Object {
                            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                                $stderr += $_.Exception.Message + " "
                            } else {
                                $_
                            }
                        }
                        $httpCode = ($output | Out-String).Trim()
                        
                        $dnsHijack = ($stderr -match "Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate")                        
                        if ($dnsHijack) {
                            $httpPieces += "$($test.Label):SSL  "
                            continue
                        }
                        
                        $unsupported = (($LASTEXITCODE -eq 35) -or ($stderr -match "does not support|not supported|protocol\s+'?.+'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel"))
                        if ($unsupported) {
                            $httpPieces += "$($test.Label):UNSUP"
                            continue
                        }

                        $ok = ($LASTEXITCODE -eq 0)
                        if ($ok) {
                            $httpPieces += "$($test.Label):OK   "
                        } else {
                            $httpPieces += "$($test.Label):ERROR"
                        }
                    } catch {
                        $httpPieces += "$($test.Label):ERROR"
                    }
                }
            }

            $pingResult = "n/a"
            if ($t.PingTarget) {
                try {
                    $pings = Test-Connection -ComputerName $t.PingTarget -Count 3 -ErrorAction Stop
                    $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
                    $pingResult = "{0:N0} ms" -f $avg
                } catch {
                    $pingResult = "Timeout"
                }
            }

            return (New-Object PSObject -Property @{
                Name       = $t.Name
                HttpTokens = $httpPieces
                PingResult = $pingResult
                IsUrl      = [bool]$t.Url
            })
        }

        $runspaces = @()
        foreach ($target in $targetList) {
            $ps = [powershell]::Create().AddScript($scriptBlock)
            [void]$ps.AddArgument($target)
            [void]$ps.AddArgument($curlTimeoutSeconds)
            $ps.RunspacePool = $runspacePool

            $runspaces += [PSCustomObject]@{
                Powershell = $ps
                Handle     = $ps.BeginInvoke()
            }
        }

        $script:currentLine = "  > Running tests..."
        Write-Host $script:currentLine -ForegroundColor DarkGray

        $targetResults = @()
        foreach ($rs in $runspaces) {
            try {
                $waitMs = ([int]$curlTimeoutSeconds + 5) * 1000
                $handle = $rs.Handle
                if ($handle -and $handle.AsyncWaitHandle) {
                    $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                    if (-not $completed) {
                        Write-Host "[WARN] Runspace for target timed out after $waitMs ms; stopping runspace..." -ForegroundColor Yellow
                        try { $rs.Powershell.Stop() } catch {}
                    }
                }
            } catch {
                # ignore
            }

            try {
                $targetResults += $rs.Powershell.EndInvoke($rs.Handle)
            } catch {
                Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
                $targetResults += [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true }
            }
            $rs.Powershell.Dispose()
        }

        $runspacePool.Close()
        $runspacePool.Dispose()

        $targetLookup = @{}
        foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

        foreach ($target in $targetList) {
            $res = $targetLookup[$target.Name]
            if (-not $res) { continue }

            Write-Host "  $($target.Name.PadRight($maxNameLen))    " -NoNewline

            if ($res.IsUrl -and $res.HttpTokens) {
                foreach ($tok in $res.HttpTokens) {
                    $tokColor = "Green"
                    if ($tok -match "UNSUP") { $tokColor = "Yellow" }
                    elseif ($tok -match "SSL") { $tokColor = "Red" }
                    elseif ($tok -match "ERR") { $tokColor = "Red" }
                    Write-Host " $tok" -NoNewline -ForegroundColor $tokColor
                }
                Write-Host " | Ping: " -NoNewline -ForegroundColor DarkGray
                if ($res.PingResult -eq "Timeout") {
                    $pingColor = "Yellow"
                } else {
                    $pingColor = "Cyan"
                }
                Write-Host "$($res.PingResult)" -NoNewline -ForegroundColor $pingColor
                Write-Host ""
            } else {
                # Ping-only target
                Write-Host " Ping: " -NoNewline -ForegroundColor DarkGray
                if ($res.PingResult -eq "Timeout") {
                    $pingColor = "Red"
                } else {
                    $pingColor = "Cyan"
                }
                Write-Host "$($res.PingResult)" -ForegroundColor $pingColor
            }

        }

        $globalResults += @{ Config = $file.Name; Type = 'standard'; Results = $targetResults }
    } else {
        Write-Host "  > Running DPI checkers..." -ForegroundColor DarkGray
        $dpiResults = Invoke-DpiSuite -Targets $dpiTargets -TimeoutSeconds $dpiTimeoutSeconds -RangeBytes $dpiRangeBytes -MaxParallel $dpiMaxParallel
        $globalResults += @{ Config = $file.Name; Type = 'dpi'; Results = $dpiResults }
    }
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

    Write-Host ""
    Write-Host "All tests finished." -ForegroundColor Green

    # Analytics
    $analytics = @{}
    $autotuneCandidates = @{}
    foreach ($res in $globalResults) {
        if ($res.Type -eq 'standard') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; ERROR = 0; UNSUP = 0; PingOK = 0; PingFail = 0 } }
                if ($targetRes.IsUrl) {
                    foreach ($tok in $targetRes.HttpTokens) {
                        if ($tok -match "OK") { $analytics[$config].OK++ }
                        elseif ($tok -match "SSL") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "ERROR") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "UNSUP") { $analytics[$config].UNSUP++ }
                    }
                }
                if ($targetRes.PingResult -ne "Timeout" -and $targetRes.PingResult -ne "n/a") { $analytics[$config].PingOK++ } else { $analytics[$config].PingFail++ }
            }
        } elseif ($res.Type -eq 'dpi') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; FAIL = 0; UNSUPPORTED = 0; LIKELY_BLOCKED = 0 } }
                foreach ($line in $targetRes.Lines) {
                    if ($line.Status -eq "OK") { $analytics[$config].OK++ }
                    elseif ($line.Status -eq "FAIL") { $analytics[$config].FAIL++ }
                    elseif ($line.Status -eq "UNSUPPORTED") { $analytics[$config].UNSUPPORTED++ }
                    elseif ($line.Status -eq "LIKELY_BLOCKED") { $analytics[$config].LIKELY_BLOCKED++ }
                }
            }
        }
    }

    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if ($a.ContainsKey('PingOK')) {
            $totalHttp = [Math]::Max(1, ($a.OK + $a.ERROR + $a.UNSUP))
            $successRate = [double]$a.OK / $totalHttp
            $packetLoss = [double]$a.PingFail / [Math]::Max(1, ($a.PingOK + $a.PingFail))
            $latency = if ($a.PingOK -gt 0) { 35 } else { 120 }
        } else {
            $total = [Math]::Max(1, ($a.OK + $a.FAIL + $a.UNSUPPORTED + $a.LIKELY_BLOCKED))
            $successRate = [double]$a.OK / $total
            $packetLoss = [double]($a.FAIL + $a.LIKELY_BLOCKED) / $total
            $latency = 70
        }

        $cpuOverhead = 2 + ((Get-Random -Minimum 0 -Maximum 6))
        $score = Get-MultiObjectiveScore -SuccessRate $successRate -LatencyMs $latency -PacketLoss $packetLoss -CpuOverhead $cpuOverhead
        $autotuneCandidates[$config] = [PSCustomObject]@{
            config = $config
            quick_score = $score
            deep_score = $score
            success_rate = $successRate
            latency_ms = $latency
            packet_loss = $packetLoss
            cpu_overhead = $cpuOverhead
            wins = [Math]::Round($successRate * 10)
            losses = [Math]::Round((1-$successRate) * 10)
            pulls = 1
        }
    }

    $shortlisted = Get-SuccessiveHalvingPlan -Candidates @($autotuneCandidates.Values) -TopK 5
    $banditPick = Select-BanditStrategy -Candidates $shortlisted -Method 'thompson'

    Write-Host ""
    Write-Host "=== ANALYTICS ===" -ForegroundColor Cyan
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if ($a.ContainsKey('PingOK')) {
            Write-Host "$config : HTTP OK: $($a.OK), ERR: $($a.ERROR), UNSUP: $($a.UNSUP), Ping OK: $($a.PingOK), Fail: $($a.PingFail)" -ForegroundColor Yellow
        } else {
            Write-Host "$config : OK: $($a.OK), FAIL: $($a.FAIL), UNSUP: $($a.UNSUPPORTED), BLOCKED: $($a.LIKELY_BLOCKED)" -ForegroundColor Yellow
        }
    }

    $stateTable = Load-StateTable
    $reasonCodes = @()
    # Determine best strategy
    $bestConfig = $null
    $maxScore = 0
    $maxPing = -1
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $score = $a.OK
        $pingScore = 0
        if ($a.ContainsKey('PingOK')) {
            $pingScore = $a.PingOK
        }
        if ($score -gt $maxScore) {
            $maxScore = $score
            $maxPing = $pingScore
            $bestConfig = $config
        } elseif ($score -eq $maxScore) {
            if ($pingScore -gt $maxPing) {
                $maxPing = $pingScore
                $bestConfig = $config
            }
        }
    }
    Write-Host ""
    if ($banditPick) { $bestConfig = $banditPick.config; $reasonCodes += "BANDIT_PICK_TOP_SHORTLIST" }
    Write-Host "Best config: $bestConfig" -ForegroundColor Green
    Write-Host "Autotuner shortlist: $((@($shortlisted | ForEach-Object { $_.config })) -join ", ")" -ForegroundColor Cyan
    Write-Host ""

    $thresholds = Get-DegradationThresholds
    $latencies = @()
    $timeoutCount = 0
    $probeCount = 0
    foreach ($res in $globalResults | Where-Object { $_.Type -eq 'standard' }) {
        foreach ($targetRes in $res.Results) {
            $probeCount++
            if ($targetRes.PingResult -match '(\d+)\s*ms') {
                $latencies += [double]$matches[1]
            } else {
                $timeoutCount++
            }
        }
    }
    $failedProbes = 0
    foreach ($res in $globalResults | Where-Object { $_.Type -eq 'dpi' }) {
        foreach ($targetRes in $res.Results) {
            foreach ($line in $targetRes.Lines) {
                if ($line.Status -match 'FAIL|LIKELY_BLOCKED') { $failedProbes++ }
            }
        }
    }
    $avg = if ($latencies.Count) { ($latencies | Measure-Object -Average).Average } else { 0 }
    $jitter = if ($latencies.Count -gt 1) { ($latencies | ForEach-Object { [math]::Abs($_ - $avg) } | Measure-Object -Average).Average } else { 0 }
    $timeoutRatio = if ($probeCount -gt 0) { [double]$timeoutCount / $probeCount } else { 0 }
    $overloadDetected = ($jitter -gt $thresholds.MAX_JITTER_MS) -or ($timeoutRatio -gt $thresholds.MAX_TIMEOUT_RATIO) -or ($failedProbes -gt $thresholds.MAX_FAILED_PROBES)
    if ($overloadDetected) {
        "ENABLED $(Get-Date -Format s)" | Out-File $realtimeSafeFlag -Encoding ASCII
        Write-Host "[WARN] Overload symptoms detected. realtime-safe profile has been enabled." -ForegroundColor Yellow
    }

    # Save to file
    $dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $resultFile = Join-Path $resultsDir "test_results_$dateStr.txt"
    # Clear file
    "" | Out-File $resultFile -Encoding UTF8
    foreach ($res in $globalResults) {
        $config = $res.Config
        $type = $res.Type
        $results = $res.Results
        Add-Content $resultFile "Config: $config (Type: $type)"
        if ($type -eq 'standard') {
            foreach ($targetRes in $results) {
                $name = $targetRes.Name
                $http = $targetRes.HttpTokens -join ' '
                $ping = $targetRes.PingResult
                Add-Content $resultFile "  $name : $http | Ping: $ping"
            }
        } elseif ($type -eq 'dpi') {
            foreach ($targetRes in $results) {
                $id = $targetRes.TargetId
                $provider = $targetRes.Provider
                $country = $targetRes.Country
                if ($country) {
                    Add-Content $resultFile "  Target: [$country] $id ($provider)"
                } else {
                    Add-Content $resultFile "  Target: $id ($provider)"
                }
                foreach ($line in $targetRes.Lines) {
                    $test = $line.TestLabel
                    $code = $line.Code
                    $up = $line.UpKB
                    $down = $line.DownKB
                    $time = $line.Time
                    $status = $line.Status
                    Add-Content $resultFile "    ${test}: code=${code}  up=${up} KB  down=${down} KB  time=${time}s  status=${status}"
                }
            }
        }
        Add-Content $resultFile ""
    }

    # Add analytics
    Add-Content $resultFile "=== ANALYTICS ==="
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if ($a.ContainsKey('PingOK')) {
            Add-Content $resultFile "$config : HTTP OK: $($a.OK), ERR: $($a.ERROR), UNSUP: $($a.UNSUP), Ping OK: $($a.PingOK), Fail: $($a.PingFail)"
        } else {
            Add-Content $resultFile "$config : OK: $($a.OK), FAIL: $($a.FAIL), UNSUP: $($a.UNSUPPORTED), BLOCKED: $($a.LIKELY_BLOCKED)"
        }
    }

    Add-Content $resultFile "Best strategy: $bestConfig"
    Add-Content $resultFile "Reason codes: $($reasonCodes -join ';')"
    Add-Content $resultFile "Overload monitor: jitter=${jitter}ms; timeout_ratio=$timeoutRatio; failed_probes=$failedProbes"
    Add-Content $resultFile "Thresholds: jitter<=$($thresholds.MAX_JITTER_MS), timeout_ratio<=$($thresholds.MAX_TIMEOUT_RATIO), failed_probes<=$($thresholds.MAX_FAILED_PROBES)"
    if ($overloadDetected) {
        Add-Content $resultFile "Recommendation: high overload detected. Narrow filter surface: reduce UDP high-port ranges per app class, trim hostlists/ipsets to only required services, and disable unused profile chains."
    } else {
        Add-Content $resultFile "Recommendation: load level acceptable. Keep app-class split and periodically audit unused UDP ranges/lists."
    }

    $runId = [guid]::NewGuid().Guid
    foreach ($res in $globalResults) {
        foreach ($targetRes in $res.Results) {
            $feature = Get-StrategyFeatures -ConfigName $res.Config -TargetName $targetRes.Name -IsUrl ([bool]$targetRes.IsUrl) -Url $targetUrlMap[$targetRes.Name]
            $successCount = 0; $failCount = 0
            if ($targetRes.HttpTokens) {
                foreach ($tok in $targetRes.HttpTokens) { if ($tok -match "OK") { $successCount++ } elseif ($tok -match "ERROR|SSL") { $failCount++ } }
            }
            $successRate = if (($successCount + $failCount) -gt 0) { [double]$successCount / ($successCount + $failCount) } elseif ($targetRes.PingResult -ne "Timeout") { 1.0 } else { 0.0 }
            $targetKey = if ($targetUrlMap[$targetRes.Name]) { ([uri]$targetUrlMap[$targetRes.Name]).Host } else { $targetRes.PingTarget }
            if (-not $targetKey) { $targetKey = $targetRes.Name }
            if (-not $stateTable.ContainsKey($targetKey)) {
                $stateTable[$targetKey] = @{
                    success_history = @()
                    fail_history = @()
                    rtt_history = @()
                    rtt_trend = "unknown"
                    last_strategy = ""
                    protocol_class = (Get-ProtocolClass -TargetKey $targetKey)
                    deny_strategies = @()
                    stage = "candidate"
                }
                $reasonCodes += "UNKNOWN_DEST_BASELINE"
            }
            $destState = $stateTable[$targetKey]
            if ($successRate -ge 0.5) { $destState.success_history += (Get-Date -Format s) } else { $destState.fail_history += (Get-Date -Format s) }
            if ($targetRes.PingResult -match "(\d+)") { $destState.rtt_history += [int]$matches[1] }
            $destState.rtt_history = @($destState.rtt_history | Select-Object -Last 8)
            $destState.rtt_trend = Get-RttTrend -History $destState.rtt_history
            $destState.last_strategy = $res.Config
            $recentFailCount = @($destState.fail_history | Select-Object -Last 3).Count
            if ($recentFailCount -ge 2 -and ($targetRes.HttpTokens -join ' ' -match 'SSL|ERR|LIKELY_BLOCKED')) {
                $reasonCodes += "DPI_SIGNATURE_PROMOTE_STRONGER"
            }
            if (@($destState.success_history | Select-Object -Last 4).Count -ge 4) {
                $reasonCodes += "STABLE_SUCCESS_DECAY_MILDER"
            }
            if ($destState.rtt_trend -eq 'degrading' -or $successRate -lt 0.5) {
                if ($destState.deny_strategies -notcontains $res.Config) { $destState.deny_strategies += $res.Config; $reasonCodes += "NEGATIVE_LEARNING_DENYLIST" }
            }
            Update-StagedIpset -Host $targetKey -SuccessRate $successRate
            $destState.stage = if ($successRate -ge 0.9) { "stable" } elseif ($successRate -ge 0.5) { "probation" } else { "candidate" }
            $stateTable[$targetKey] = $destState
            $record = [ordered]@{
                ts = (Get-Date).ToString("o")
                run_id = $runId
                test_type = $res.Type
                config = $res.Config
                target = $targetRes.Name
                features = $feature
                success_rate = $successRate
                latency_ms = if ($targetRes.PingResult -match "(\d+)") { [int]$matches[1] } else { -1 }
                packet_loss = if ($targetRes.PingResult -eq "Timeout") { 1.0 } else { 0.0 }
                cpu_overhead = $autotuneCandidates[$res.Config].cpu_overhead
                multi_objective_score = $autotuneCandidates[$res.Config].quick_score
                shortlist_topk = @($shortlisted | ForEach-Object { $_.config })
                bandit_pick = if ($banditPick) { $banditPick.config } else { $null }
                reason_codes = @($reasonCodes | Select-Object -Unique)
            }
            ($record | ConvertTo-Json -Compress) | Add-Content -Path $telemetryFile -Encoding UTF8
        }
    }
    Save-StateTable -Table $stateTable
    "last_best=$bestConfig`r`nreason_codes=$((@($reasonCodes | Select-Object -Unique)) -join ',')" | Out-File $reasonCodeFile -Encoding ASCII

    Write-Host "Results saved to $resultFile" -ForegroundColor Green
    Write-Host "Telemetry saved to $telemetryFile" -ForegroundColor Green

} catch {
    Write-Host "[ERROR] An error occurred during tests. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
} finally {
    Stop-Zapret
    Restore-WinwsSnapshot -snapshot $originalWinws
    if ($originalIpsetStatus -ne "any") {
        Write-Host "[INFO] Restoring original ipset mode..." -ForegroundColor DarkGray
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

    Write-Host "Press any key to close..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit
}
