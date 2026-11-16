param(
    # The run to reverse, e.g. 20261102-220323 (the journal file name without .csv)
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config.json'),
    # Without -Apply the script only reports what it would do (dry run)
    [switch]$Apply
)

# Loads Resolve-ConfigPath
. (Join-Path $PSScriptRoot 'LabFiler.Common.ps1')

# --- Find the journal for that run ---
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Host "Config file not found: $ConfigPath"
    exit 1
}
$ConfigPath  = (Resolve-Path -Path $ConfigPath).Path
$configDir   = Split-Path -Path $ConfigPath -Parent
$config      = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$journalPath = Resolve-ConfigPath $configDir $config.JournalPath

$journalFile = Join-Path $journalPath "$RunId.csv"
if (-not (Test-Path -LiteralPath $journalFile -PathType Leaf)) {
    Write-Host "No journal found for run '$RunId': $journalFile"
    exit 1
}

# @() keeps it a list even when the journal has a single row
$rows = @(Import-Csv -LiteralPath $journalFile -Encoding UTF8)
# Undo in reverse order, last action first
[array]::Reverse($rows)

$undoStart = Get-Date
$undoId    = 'undo-' + $undoStart.ToString('yyyyMMdd-HHmmss')

if ($Apply) {
    $mode = 'APPLY (files will be moved back)'
}
else {
    $mode = 'DRY RUN (nothing will be changed)'
}
Write-Host "Undoing run $RunId ($($rows.Count) journal row(s)) - $mode"

# --- Decide what can be undone ---
$plan = @()
foreach ($row in $rows) {
    # Skipped rows in an undo journal can have an empty Source, so fall back to Destination
    $namePath = $row.Source
    if ($namePath -eq '') {
        $namePath = $row.Destination
    }
    if ($namePath -eq '') {
        # A 'Run' row from a quiet night has no file at all
        $name = '(none)'
    }
    else {
        $name = Split-Path -Path $namePath -Leaf
    }
    $status = 'Undo'
    $reason = ''

    if (($row.Result -ne 'Done') -or ($row.Source -eq '')) {
        # Failed actions, review items and quiet-night rows changed nothing
        $status = 'Skip'
        $reason = "nothing to undo ($($row.Action), $($row.Result))"
    }
    elseif ($row.Destination -eq '') {
        # Purges and Delete-mode removes have no destination: the file is gone
        $status = 'Skip'
        $reason = "$($row.Action) deleted the file, it cannot be restored"
    }
    elseif (-not (Test-Path -LiteralPath $row.Destination)) {
        $status = 'Skip'
        $reason = "file is no longer at $($row.Destination)"
    }
    elseif (Test-Path -LiteralPath $row.Source) {
        # Never overwrite: something with this name is already back in the original place
        $status = 'Skip'
        $reason = "something already exists at $($row.Source)"
    }
    else {
        $backTo = Split-Path -Path (Split-Path -Path $row.Source -Parent) -Leaf
        $reason = "back to $backTo"
    }

    $plan += [pscustomobject]@{
        Action = $row.Action
        Name   = $name
        From   = $row.Destination
        To     = $row.Source
        Status = $status
        Reason = $reason
    }
}

$plan | Format-Table Action, Name, Status, Reason -AutoSize -Wrap

$toUndo  = @($plan | Where-Object { $_.Status -eq 'Undo' })
$skipped = @($plan | Where-Object { $_.Status -eq 'Skip' })
Write-Host "Summary: $($toUndo.Count) to undo, $($skipped.Count) skipped"

if (-not $Apply) {
    Write-Host "Dry run: nothing was changed. Run again with -Apply to undo."
    exit 0
}

# --- Move files back, writing each step to a new journal ---
# The undo journal uses the same columns, so an undo can itself be undone
$undoJournal = Join-Path $journalPath "$undoId.csv"
$failed      = 0

foreach ($item in $plan) {
    $outcome   = 'Skipped'
    $errorText = ''
    $from      = $item.From
    $to        = $item.To

    if ($item.Status -eq 'Undo') {
        $outcome = 'Done'
        try {
            $toFolder = Split-Path -Path $to -Parent
            if (-not (Test-Path -LiteralPath $toFolder)) {
                New-Item -ItemType Directory -Path $toFolder -Force | Out-Null
            }
            # Without -Force, Move-Item refuses to overwrite an existing file
            Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
        }
        catch {
            $outcome   = 'Failed'
            $errorText = $_.Exception.Message
            $failed++
        }
    }

    # Source/Destination describe this move: from where the file was, to where it went back
    [pscustomobject]@{
        RunId       = $undoId
        Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Action      = 'Undo'
        Source      = $from
        Destination = $to
        Result      = $outcome
        Reason      = $item.Reason
        Error       = $errorText
    } | Export-Csv -LiteralPath $undoJournal -Append -NoTypeInformation -Encoding UTF8

    Write-Host "  $outcome  $($item.Action)  $($item.Name)"
}

Write-Host "Undo journal: $undoJournal"

if ($failed -gt 0) {
    Write-Host "$failed move(s) failed. See the Error column in the undo journal."
    exit 1
}
