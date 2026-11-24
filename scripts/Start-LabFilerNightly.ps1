param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config.json')
)

# What the scheduled task runs every night: the filer (with -Apply), then the morning report.
# A scheduled task has no window, so everything printed is also saved to a log file,
# next to that night's journal:
#   Journal/<YYYY>/<MM Mon>/<RunId> nightly.log
# The journal records what happened to each file; the log is for when something went wrong,
# e.g. Edge couldn't make the PDF.
# If the config can't be read (so the journal folder is unknown), the log goes to
#   Logs/<YYYY>/<MM Mon>/<RunId> nightly.log   (next to the scripts folder)
# instead, so even that night leaves a record of what went wrong.

# Loads Resolve-ConfigPath, New-RunId and Get-MonthFolder
. (Join-Path $PSScriptRoot 'LabFiler.Common.ps1')

$start   = Get-Date
$logBase = $null
$whyFallback = ''

# --- Find the journal folder, to put the log in ---
# try/catch: a broken config.json shouldn't stop the log being written
try {
    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        $whyFallback = "config file not found: $ConfigPath"
    }
    else {
        $fullConfig  = (Resolve-Path -Path $ConfigPath).Path
        $config      = Get-Content -Path $fullConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $journalPath = Resolve-ConfigPath (Split-Path -Path $fullConfig -Parent) $config.JournalPath
        # The journal folder itself must already exist (the filer checks this too);
        # only the year and month folders inside it are created here
        if (($null -ne $journalPath) -and (Test-Path -LiteralPath $journalPath -PathType Container)) {
            $logBase = $journalPath
        }
        else {
            $whyFallback = "journal folder not found: $($config.JournalPath)"
        }
    }
}
catch {
    $whyFallback = "config could not be read: $($_.Exception.Message)"
}

if ($null -eq $logBase) {
    $logBase = Join-Path $PSScriptRoot '../Logs'
}

$logDir = Get-MonthFolder $logBase $start
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir ((New-RunId $start) + ' nightly.log')

# Start-Transcript copies everything shown on screen (including Write-Host) into the log
Start-Transcript -LiteralPath $logFile | Out-Null

if ($whyFallback -ne '') {
    Write-Host "Log saved in the Logs folder instead of the journal: $whyFallback"
}

# Runs one of the scripts and returns its exit code (0 = fine).
# '&' runs another script. When that script ends with 'exit 1', only it stops (not this one),
# and its exit code is left in $LASTEXITCODE. A script that finishes without 'exit' leaves
# $LASTEXITCODE alone, so it's set to 0 first. An unexpected crash is caught and logged as 1.
function Invoke-Step {
    param(
        [string]$Script,
        [hashtable]$Arguments
    )
    $global:LASTEXITCODE = 0
    try {
        # @Arguments 'splats' the hashtable: each key becomes a -Name value parameter.
        # Out-Host sends the script's table to the screen (and log); otherwise it would
        # become part of what this function returns, instead of just the exit code.
        & (Join-Path $PSScriptRoot $Script) @Arguments | Out-Host
        return $global:LASTEXITCODE
    }
    catch {
        Write-Host "$Script stopped with an error: $($_.Exception.Message)"
        return 1
    }
}

Write-Host '=== Filer ==='
$filerExit = Invoke-Step 'Invoke-LabFiler.ps1' @{ ConfigPath = $ConfigPath; Apply = $true }

# The report runs even if the filer had problems, so the problems show up in it
Write-Host ''
Write-Host '=== Morning report ==='
$reportExit = Invoke-Step 'New-MorningReport.ps1' @{ ConfigPath = $ConfigPath }

Write-Host ''
Write-Host "Filer exit code: $filerExit. Report exit code: $reportExit."
Stop-Transcript | Out-Null

# Task Scheduler shows this as the task's "Last Run Result": 0 = fine, 1 = something needs a look
if (($filerExit -ne 0) -or ($reportExit -ne 0)) {
    exit 1
}
exit 0
