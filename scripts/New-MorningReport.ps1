param(
    # The run to report on, e.g. 2026-11-23_020004. Defaults to the newest filer run.
    [string]$RunId = '',
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config.json')
)

# Loads Resolve-ConfigPath
. (Join-Path $PSScriptRoot 'LabFiler.Common.ps1')

# --- Load the config ---
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Host "Config file not found: $ConfigPath"
    exit 1
}
$ConfigPath = (Resolve-Path -Path $ConfigPath).Path
$configDir  = Split-Path -Path $ConfigPath -Parent
$config     = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

foreach ($key in @('ReportPath', 'ReportTodayFolder', 'ReportArchiveFolder')) {
    if ($null -eq $config.$key) {
        Write-Host "Missing setting: $key"
        exit 1
    }
}
$rootPath    = Resolve-ConfigPath $configDir $config.RootPath
$archivePath = Resolve-ConfigPath $configDir $config.ArchivePath
$holdingPath = Resolve-ConfigPath $configDir $config.HoldingPath
$journalPath = Resolve-ConfigPath $configDir $config.JournalPath
$reportPath  = Resolve-ConfigPath $configDir $config.ReportPath

# Today's Report holds only the newest report; older ones move to Archived Reports
$todayDir   = Join-Path $reportPath $config.ReportTodayFolder
$archiveDir = Join-Path $reportPath $config.ReportArchiveFolder
foreach ($dir in @($todayDir, $archiveDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# --- Pick the journal ---
# Only the normal morning report (no -RunId) replaces Today's Report
$isMorningReport = ($RunId -eq '')
if ($isMorningReport) {
    # Journals sit in year/month folders, so look through all of them (-Recurse).
    # Names start with the run ID, so sorting by name puts the newest last. Undo journals are not nightly runs.
    $latest = Get-ChildItem -LiteralPath $journalPath -File -Recurse |
        Where-Object { $_.Name -like '* run.csv' } |
        Sort-Object Name |
        Select-Object -Last 1
    if ($null -eq $latest) {
        Write-Host "No filer runs found in $journalPath"
        exit 1
    }
    # '2026-11-23_020004 run' -> '2026-11-23_020004'
    $RunId = $latest.BaseName -replace ' run$', ''
}
$runTime = ConvertFrom-RunId $RunId
if ($null -eq $runTime) {
    Write-Host "'$RunId' is not a run ID. Run IDs look like 2026-11-23_020004."
    exit 1
}
$journalFile = Find-JournalFile $journalPath $RunId
if ($null -eq $journalFile) {
    Write-Host "No journal found for run '$RunId' in $journalPath"
    exit 1
}
$rows = @(Import-Csv -LiteralPath $journalFile -Encoding UTF8)

# --- Helpers ---

# Makes text safe to put inside HTML (file names can contain & < >)
function Format-Html {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

# Shows the folder a path is in, relative to the CAD4 folders, e.g. 'Scans' or 'Archive/2026/09/Scans'
function Get-ShortFolder {
    param([string]$FullPath)
    if ($FullPath -eq '') {
        return ''
    }
    # Compare with forward slashes so Windows and Mac paths behave the same
    $folder = (Split-Path -Path $FullPath -Parent) -replace '\\', '/'
    $bases = @(
        @{ Path = ($archivePath -replace '\\', '/'); Label = 'Archive' },
        @{ Path = ($holdingPath -replace '\\', '/'); Label = 'Holding' },
        @{ Path = ($rootPath    -replace '\\', '/'); Label = '' }
    )
    # Longest base first, in case one of them sits inside another
    foreach ($b in ($bases | Sort-Object { $_.Path.Length } -Descending)) {
        if ($folder.StartsWith($b.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rest  = $folder.Substring($b.Path.Length).TrimStart('/')
            $parts = @($b.Label, $rest) | Where-Object { $_ -ne '' }
            return ($parts -join '/')
        }
    }
    return $folder
}

# Turns a raw error into something short for the report. The journal keeps the full message.
function Get-FriendlyError {
    param([string]$Text)
    if ($Text -match 'being used by another process') {
        return 'The file is open in another program. It will be tried again tonight.'
    }
    if ($Text -match 'Access to the path .* is denied') {
        return 'Windows refused access to the file. It may be open or read-only.'
    }
    if ($Text -match 'Could not find|does not exist') {
        return 'The file was gone before it could be moved.'
    }
    # Anything else: keep the message but show only file names, not full paths
    return ($Text -replace "'[^']*[/\\]([^'/\\]+)'", "'`$1'")
}

# Gets the file name from whichever path the row has
function Get-RowName {
    param($Row)
    if ($Row.Source -ne '') {
        return Split-Path -Path $Row.Source -Leaf
    }
    return Split-Path -Path $Row.Destination -Leaf
}

# Builds one titled table. Columns is a list of @{ Header = ...; Value = { scriptblock using $_ } }.
function New-Section {
    param(
        [string]$Title,
        [object[]]$Items,
        [object[]]$Columns
    )
    if (@($Items).Count -eq 0) {
        return ''
    }
    $html = "<h2>$(Format-Html $Title) <span class='count'>$(@($Items).Count)</span></h2>`n<table>`n<tr>"
    foreach ($c in $Columns) {
        $html += "<th>$(Format-Html $c.Header)</th>"
    }
    $html += "</tr>`n"
    foreach ($item in $Items) {
        $html += '<tr>'
        foreach ($c in $Columns) {
            # ForEach-Object runs the column's scriptblock with $_ set to this item
            $value = $item | ForEach-Object $c.Value
            $html += "<td>$(Format-Html $value)</td>"
        }
        $html += "</tr>`n"
    }
    $html += "</table>`n"
    return $html
}

# --- Group the journal rows ---
$failedRows  = @($rows | Where-Object { $_.Result -eq 'Failed' })
$reviewRows  = @($rows | Where-Object { $_.Result -eq 'Review' })
$movedRows   = @($rows | Where-Object { ($_.Result -eq 'Done') -and ($_.Action -eq 'Move') })
$archiveRows = @($rows | Where-Object { ($_.Result -eq 'Done') -and ($_.Action -eq 'Archive') })
$removedRows = @($rows | Where-Object { ($_.Result -eq 'Done') -and ($_.Action -eq 'Remove') })
$purgedRows  = @($rows | Where-Object { ($_.Result -eq 'Done') -and ($_.Action -eq 'Purge') })

# A report about an old run means last night's run didn't happen
$hoursSinceRun = ((Get-Date) - $runTime).TotalHours
$isStale       = $hoursSinceRun -gt 24

$attentionCount = $failedRows.Count + $reviewRows.Count
if ($isStale) {
    $attentionCount++
}

if ($attentionCount -eq 0) {
    $status      = 'Nothing needs your attention.'
    $statusClass = 'ok'
}
else {
    $status      = "$attentionCount item(s) need your attention."
    $statusClass = 'warn'
}

# --- Build the page ---
$title = "$([System.Environment]::MachineName) file tidy-up: " + $runTime.ToString('dddd d MMMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture)

$fileColumn = @{ Header = 'File'; Value = { Get-RowName $_ } }
$fromColumn = @{ Header = 'From'; Value = { Get-ShortFolder $_.Source } }
$toColumn   = @{ Header = 'To';   Value = { Get-ShortFolder $_.Destination } }

$body = ''
if ($isStale) {
    $body += "<p class='stale'>This report is for a run from $(Format-Html $runTime.ToString('yyyy-MM-dd HH:mm')). " +
             "No newer run was found, so last night's run may not have happened.</p>`n"
}
$body += New-Section 'Could not be done' $failedRows @(
    $fileColumn,
    @{ Header = 'Folder';  Value = { Get-ShortFolder $_.Source } },
    @{ Header = 'Tried';   Value = { $_.Action } },
    @{ Header = 'Problem'; Value = { Get-FriendlyError $_.Error } }
)
$body += New-Section 'Needs a person to look at' $reviewRows @(
    $fileColumn,
    @{ Header = 'Folder'; Value = { Get-ShortFolder $_.Source } },
    @{ Header = 'Why';    Value = { $_.Reason } }
)
$body += New-Section 'Moved to the right folder' $movedRows   @($fileColumn, $fromColumn, $toColumn)
$body += New-Section 'Archived'                  $archiveRows @($fileColumn, $fromColumn, $toColumn)
$body += New-Section 'Removed (kept in Holding)' $removedRows @($fileColumn, $fromColumn, $toColumn)
$body += New-Section 'Deleted from Holding'      $purgedRows  @(
    $fileColumn,
    @{ Header = 'Held in'; Value = { Get-ShortFolder $_.Source } }
)
if (($failedRows.Count + $reviewRows.Count + $movedRows.Count + $archiveRows.Count +
     $removedRows.Count + $purgedRows.Count) -eq 0) {
    $body += "<p>No files needed any action.</p>`n"
}

$summary = "Moved $($movedRows.Count) &middot; Archived $($archiveRows.Count) &middot; " +
           "Removed $($removedRows.Count) &middot; Deleted from Holding $($purgedRows.Count)"

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>$(Format-Html $title)</title>
<style>
  @page { size: Letter; margin: 15mm; }
  body { font-family: "Segoe UI", Helvetica, Arial, sans-serif; font-size: 10.5pt; color: #222; margin: 0; }
  h1 { font-size: 16pt; margin: 0 0 4px 0; }
  .meta { color: #666; margin: 0 0 12px 0; }
  .status { padding: 8px 12px; border-radius: 4px; font-weight: 600; margin: 0 0 6px 0; }
  .ok   { background: #e7f4ea; color: #1e5631; }
  .warn { background: #fdf0e1; color: #8a4b08; }
  .summary { color: #444; margin: 0 0 18px 0; }
  .stale { background: #fde8e8; color: #8a1c1c; padding: 8px 12px; border-radius: 4px; }
  h2 { font-size: 12pt; margin: 18px 0 6px 0; border-bottom: 1px solid #ddd; padding-bottom: 3px; page-break-after: avoid; }
  .count { color: #888; font-weight: normal; }
  table { border-collapse: collapse; width: 100%; table-layout: fixed; page-break-inside: auto; }
  th:first-child { width: 45%; }
  td { overflow-wrap: anywhere; }
  tr { page-break-inside: avoid; }
  th { text-align: left; font-weight: 600; color: #555; border-bottom: 1px solid #ccc; padding: 4px 8px 4px 0; }
  td { border-bottom: 1px solid #eee; padding: 4px 8px 4px 0; vertical-align: top; }
  .footer { color: #999; font-size: 8.5pt; margin-top: 24px; }
</style>
</head>
<body>
<h1>$(Format-Html $title)</h1>
<p class="meta">Run started $(Format-Html $runTime.ToString('HH:mm')) on $(Format-Html ([System.Environment]::MachineName))</p>
<p class="status $statusClass">$(Format-Html $status)</p>
<p class="summary">$summary</p>
$body
<p class="footer">Run ID $(Format-Html $RunId). Moves, archives and removals can be undone with Undo-LabFilerRun.ps1 -RunId $(Format-Html $RunId).</p>
</body>
</html>
"@

# --- Decide where the report goes ---
if ($isMorningReport) {
    # Yesterday's report (and anything else left in Today's Report) moves to the archive first.
    # -Force replaces a same-named archived copy: reports can always be rebuilt from the journal.
    # Archived reports are kept in year/month folders, e.g. Archived Reports/2026/11 Nov/.
    foreach ($old in (Get-ChildItem -LiteralPath $todayDir -File)) {
        # The month comes from the date in the name ('File tidy-up 2026-11-22 0204.pdf').
        # A file named some other way goes by its modified date instead.
        $oldDate = $old.LastWriteTime
        if ($old.Name -match '(\d{4}-\d{2}-\d{2}) \d{4}') {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $oldDate = $parsed
            }
        }
        $oldTarget = Get-MonthFolder $archiveDir $oldDate
        if (-not (Test-Path -LiteralPath $oldTarget)) {
            New-Item -ItemType Directory -Path $oldTarget -Force | Out-Null
        }
        Move-Item -LiteralPath $old.FullName -Destination (Join-Path $oldTarget $old.Name) -Force
        Write-Host "Archived old report: $($old.Name)"
    }
    $targetDir = $todayDir
}
else {
    # A report rebuilt for an older run goes straight to that run's month in the archive
    $targetDir = Get-MonthFolder $archiveDir $runTime
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
}

# A name Ben can read, e.g. 'File tidy-up 2026-11-10 0200'
$reportName = 'File tidy-up ' + $runTime.ToString('yyyy-MM-dd HHmm')
$pdfFile    = Join-Path $targetDir "$reportName.pdf"

# The HTML page is only a step towards the PDF, so it's built in the temp folder
$htmlFile = Join-Path ([System.IO.Path]::GetTempPath()) "labfiler-report-$RunId.html"
Set-Content -LiteralPath $htmlFile -Value $html -Encoding UTF8

# If no PDF can be made, the HTML page goes in its place, so there's still a report to read
function Save-HtmlInstead {
    $fallback = Join-Path $targetDir "$reportName.html"
    Move-Item -LiteralPath $htmlFile -Destination $fallback -Force
    Write-Host "Report saved as HTML instead: $fallback"
}

# --- Turn the page into a PDF with a Chromium browser (Edge on Windows) ---
$browser = $config.PdfBrowserPath
if (($null -eq $browser) -or ($browser -eq '')) {
    Write-Host "PdfBrowserPath is not set, so no PDF was made."
    Save-HtmlInstead
    exit 0
}
if (-not (Test-Path -LiteralPath $browser -PathType Leaf)) {
    Write-Host "PDF browser not found: $browser"
    Save-HtmlInstead
    exit 1
}

if (Test-Path -LiteralPath $pdfFile) {
    Remove-Item -LiteralPath $pdfFile
}

# A separate browser profile, so a browser someone already has open doesn't get in the way
$profileDir = Join-Path ([System.IO.Path]::GetTempPath()) 'labfiler-pdf-profile'
# UriKind Absolute matters: a plain [System.Uri] cast of '/var/...' on macOS gives an empty
# relative address, and the browser then prints its new-tab page instead of the report
$fileUri    = (New-Object System.Uri($htmlFile, [System.UriKind]::Absolute)).AbsoluteUri
if ($fileUri -eq '') {
    Write-Host "Could not turn $htmlFile into a file address for the browser."
    Save-HtmlInstead
    exit 1
}
$logFile    = Join-Path ([System.IO.Path]::GetTempPath()) 'labfiler-pdf-log.txt'
$errFile    = Join-Path ([System.IO.Path]::GetTempPath()) 'labfiler-pdf-errors.txt'

# Is this the Windows SYSTEM account (how the nightly task runs)?
# The browser's sandbox, which locks down the pages it opens, won't start under SYSTEM, and the
# browser then quits without a word. Turning it off is safe here: the browser only ever opens
# our own report file, never a website. Normal accounts keep the sandbox.
$runningAsSystem = $false
if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    $runningAsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

# Start-Process joins the arguments with spaces, so any with spaces in them need their own quotes
#   --enable-logging=stderr   the browser writes what it's doing to $errFile, so a failure has messages
$browserArgs = @(
    '--headless',
    '--disable-gpu',
    '--no-pdf-header-footer',
    '--enable-logging=stderr',
    "--user-data-dir=`"$profileDir`"",
    "--print-to-pdf=`"$pdfFile`""
)
if ($runningAsSystem) {
    $browserArgs += '--no-sandbox'
}
# The page to print goes last
$browserArgs = ($browserArgs + "`"$fileUri`"") -join ' '

# -PassThru hands back the finished process, so its exit code can be logged
$process = Start-Process -FilePath $browser -ArgumentList $browserArgs -Wait -NoNewWindow -PassThru `
                         -RedirectStandardOutput $logFile -RedirectStandardError $errFile

# The browser can hand the work to a helper process and exit before the PDF is written,
# so give the PDF up to 30 seconds to appear
$waited = 0
while ((-not (Test-Path -LiteralPath $pdfFile)) -and ($waited -lt 30)) {
    Start-Sleep -Seconds 1
    $waited++
}

if (Test-Path -LiteralPath $pdfFile) {
    Remove-Item -LiteralPath $htmlFile
    Write-Host "Report: $pdfFile"
}
else {
    Write-Host "The browser did not make a PDF (browser exit code: $($process.ExitCode), running as SYSTEM: $runningAsSystem)."
    Write-Host "Its messages are in $errFile"
    Save-HtmlInstead
    exit 1
}
