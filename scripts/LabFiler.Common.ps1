# Helpers shared by the lab filer scripts. Load with:
#   . (Join-Path $PSScriptRoot 'LabFiler.Common.ps1')

# Turns a path from the config into a full path.
# Relative paths are taken as relative to the folder that holds the config file.
function Resolve-ConfigPath {
    param(
        [string]$BaseDir,
        [string]$Value
    )
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }
    return Join-Path $BaseDir $Value
}

# --- Run IDs and month folders ---
# A run ID is the time the run started, e.g. 2026-11-23_214808.
# It reads as a date, sorts in time order, has no spaces (easy to type after -RunId),
# and keeps the seconds so two runs a minute apart never share a journal.
$script:RunIdFormat = 'yyyy-MM-dd_HHmmss'

function New-RunId {
    param([datetime]$Time)
    return $Time.ToString($script:RunIdFormat)
}

# Turns a run ID back into its time. Returns $null if it isn't a valid run ID.
function ConvertFrom-RunId {
    param([string]$RunId)
    $time = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($RunId, $script:RunIdFormat,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$time)
    if ($ok) {
        return $time
    }
    return $null
}

# The year/month folder for a date, e.g. <BaseDir>/2026/11 Nov (the same layout as Ben's archive).
# InvariantCulture keeps the month name in English whatever the machine's language is.
function Get-MonthFolder {
    param(
        [string]$BaseDir,
        [datetime]$Date
    )
    $year  = $Date.ToString('yyyy')
    $month = $Date.ToString('MM MMM', [System.Globalization.CultureInfo]::InvariantCulture)
    return Join-Path (Join-Path $BaseDir $year) $month
}

# Where a journal lives: <JournalPath>/2026/11 Nov/2026-11-23_214808 run.csv
# $Kind is 'run' for a filer run or 'undo' for an undo.
function Get-JournalFile {
    param(
        [string]$JournalPath,
        [string]$RunId,
        [string]$Kind
    )
    $time = ConvertFrom-RunId $RunId
    if ($null -eq $time) {
        return $null
    }
    return Join-Path (Get-MonthFolder $JournalPath $time) "$RunId $Kind.csv"
}

# Finds the journal for a run ID, whether it was a filer run or an undo. Returns $null if there is none.
function Find-JournalFile {
    param(
        [string]$JournalPath,
        [string]$RunId
    )
    foreach ($kind in @('run', 'undo')) {
        $file = Get-JournalFile $JournalPath $RunId $kind
        if (($null -ne $file) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
            return $file
        }
    }
    return $null
}
