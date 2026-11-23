param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config.json'),
    # Without -Apply the script only reports what it would do (dry run)
    [switch]$Apply
)

# Loads Resolve-ConfigPath
. (Join-Path $PSScriptRoot 'LabFiler.Common.ps1')

# Prints every problem found, then stops the script with a failure code
function Stop-WithProblems {
    param([string[]]$Problems)
    Write-Host "Config check failed ($($Problems.Count) problem(s)):"
    foreach ($p in $Problems) {
        Write-Host "  - $p"
    }
    exit 1
}

# --- Load the config ---
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Stop-WithProblems @("Config file not found: $ConfigPath")
}
$ConfigPath = (Resolve-Path -Path $ConfigPath).Path
$configDir  = Split-Path -Path $ConfigPath -Parent

try {
    $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Stop-WithProblems @("Config file is not valid JSON: $($_.Exception.Message)")
}

# --- Every setting must be present (the checks below depend on them) ---
$problems = @()
$required = @('RootPath', 'Folders', 'ArchivePath', 'HoldingPath', 'JournalPath', 'HomeFolders',
              'HandSortSubfolders', 'IgnorePatterns', 'RemoveExtensions', 'RemoveByFolder', 'ArchiveAfterDays',
              'RemoveMode', 'HoldingDays')
foreach ($key in $required) {
    if ($null -eq $config.$key) {
        $problems += "Missing setting: $key"
    }
}
if ($problems.Count -gt 0) {
    Stop-WithProblems $problems
}

# --- Every folder must exist ---
$rootPath    = Resolve-ConfigPath $configDir $config.RootPath
$archivePath = Resolve-ConfigPath $configDir $config.ArchivePath
$holdingPath = Resolve-ConfigPath $configDir $config.HoldingPath
$journalPath = Resolve-ConfigPath $configDir $config.JournalPath

$foldersToCheck = @(
    @{ Label = 'RootPath';    Path = $rootPath },
    @{ Label = 'ArchivePath'; Path = $archivePath },
    @{ Label = 'HoldingPath'; Path = $holdingPath },
    @{ Label = 'JournalPath'; Path = $journalPath }
)
foreach ($folder in $config.Folders) {
    $foldersToCheck += @{ Label = "Folder '$folder'"; Path = (Join-Path $rootPath $folder) }
}
foreach ($f in $foldersToCheck) {
    if (-not (Test-Path -Path $f.Path -PathType Container)) {
        $problems += "$($f.Label) does not exist: $($f.Path)"
    }
}

# --- The filing rules must make sense ---
foreach ($rule in $config.HomeFolders.PSObject.Properties) {
    if (-not $rule.Name.StartsWith('.')) {
        $problems += "HomeFolders extension '$($rule.Name)' must start with a dot"
    }
    # A home can be a subfolder, e.g. 'Models/Stray FitFoot Files'; its first part must be one of the four
    $topFolder = ($rule.Value -split '/')[0]
    if ($config.Folders -notcontains $topFolder) {
        $problems += "HomeFolders sends '$($rule.Name)' to '$($rule.Value)', which is not in Folders"
    }
}
foreach ($ext in $config.RemoveExtensions) {
    if (-not $ext.StartsWith('.')) {
        $problems += "RemoveExtensions entry '$ext' must start with a dot"
    }
    if ($null -ne $config.HomeFolders.$ext) {
        $problems += "'$ext' is in both HomeFolders and RemoveExtensions"
    }
}
foreach ($rule in $config.HandSortSubfolders.PSObject.Properties) {
    if ($null -eq $config.HomeFolders.($rule.Name)) {
        $problems += "HandSortSubfolders has '$($rule.Name)', which has no HomeFolders rule"
    }
}
foreach ($rule in $config.RemoveByFolder.PSObject.Properties) {
    if ($config.Folders -notcontains $rule.Name) {
        $problems += "RemoveByFolder names '$($rule.Name)', which is not in Folders"
    }
    foreach ($ext in $rule.Value) {
        if (-not $ext.StartsWith('.')) {
            $problems += "RemoveByFolder entry '$ext' for '$($rule.Name)' must start with a dot"
        }
    }
}

# --- The other settings must have allowed values ---
if (@('Holding', 'Delete') -notcontains $config.RemoveMode) {
    $problems += "RemoveMode must be 'Holding' or 'Delete', not '$($config.RemoveMode)'"
}
foreach ($key in @('ArchiveAfterDays', 'HoldingDays')) {
    $value = $config.$key
    $isWholeNumber = ($value -is [int]) -or ($value -is [long])
    if ((-not $isWholeNumber) -or ($value -lt 1)) {
        $problems += "$key must be a whole number of 1 or more, not '$value'"
    }
}

if ($problems.Count -gt 0) {
    Stop-WithProblems $problems
}

# One timestamp for the whole run, so every file is judged against the same moment
$runStart = Get-Date
$runId    = $runStart.ToString('yyyyMMdd-HHmmss')
$runDay   = $runStart.ToString('yyyy-MM-dd')

if ($Apply) {
    $mode = 'APPLY (files will be changed)'
}
else {
    $mode = 'DRY RUN (nothing will be changed)'
}

Write-Host "Config OK: $ConfigPath"
Write-Host "  Root:    $rootPath"
Write-Host "  Archive: $archivePath"
Write-Host "  Holding: $holdingPath"
Write-Host "  Journal: $journalPath"
Write-Host "Run $runId - $mode"

# --- Classify each file (read-only) ---

# Finds the home folder for an extension: an exact rule first, then wildcard rules like '.ff*'
function Get-HomeFolder {
    param([string]$Ext)
    $exact = $config.HomeFolders.$Ext
    if ($null -ne $exact) {
        return $exact
    }
    foreach ($rule in $config.HomeFolders.PSObject.Properties) {
        # -like is a case-insensitive wildcard match, so '.FFP' matches '.ff*'
        if ($rule.Name.Contains('*') -and ($Ext -like $rule.Name)) {
            return $rule.Value
        }
    }
    return $null
}

# True for files the filer must never touch or report, e.g. FreeFileSync's sync.ffs_db
function Test-IgnoredName {
    param([string]$Name)
    foreach ($pattern in $config.IgnorePatterns) {
        if ($Name -like $pattern) {
            return $true
        }
    }
    return $false
}

# Month folders in the archive are named like '09 Sep', and only the number matters.
# Returns the existing folder starting with '09', or $null if there isn't one: the filer never
# creates archive folders, so a file with nowhere to go ends up on the review list.
# Answers are remembered, so each archive folder is only listed once per run.
$monthFolderCache = @{}
function Get-ArchiveMonthFolder {
    param(
        [string]$Year,
        [string]$Folder,
        [datetime]$Date
    )
    $month = $Date.ToString('MM')
    $key   = "$Year|$Folder|$month"
    if ($monthFolderCache.ContainsKey($key)) {
        return $monthFolderCache[$key]
    }

    $name   = $null
    $parent = Join-Path (Join-Path $archivePath $Year) $Folder
    if (Test-Path -LiteralPath $parent) {
        # '09 Sep', '09 September' and '09' all count; '090' or '9 Sep' don't
        $existing = Get-ChildItem -LiteralPath $parent -Directory |
            Where-Object { $_.Name -match "^$month(\s|$)" } |
            Sort-Object Name |
            Select-Object -First 1
        if ($null -ne $existing) {
            $name = $existing.Name
        }
    }
    $monthFolderCache[$key] = $name
    return $name
}

# Decides what should happen to one file and where it would go
function Get-FileAction {
    param(
        [System.IO.FileInfo]$File,
        [string]$Folder
    )
    $ext = $File.Extension

    # Age uses the newest of the two dates, so current work carrying an old date is protected
    $newest = $File.CreationTime
    if ($File.LastWriteTime -gt $newest) {
        $newest = $File.LastWriteTime
    }
    $ageDays = [int][math]::Floor(($runStart - $newest).TotalDays)

    $action      = 'Review'
    $destination = $null
    # Short name of the destination folder, for messages
    $destLabel   = ''
    $reason      = ''

    # Extensions removed only from this folder, e.g. .pdf in NC Programs (empty for most folders)
    $folderRemovals = $config.RemoveByFolder.$Folder
    if ($null -eq $folderRemovals) {
        $folderRemovals = @()
    }

    if ($ext -eq '') {
        $reason = 'the file has no extension'
    }
    elseif (($config.RemoveExtensions -contains $ext) -or ($folderRemovals -contains $ext)) {
        $action = 'Remove'
        if ($folderRemovals -contains $ext) {
            $removeText = "$ext files are removed from $Folder"
        }
        else {
            $removeText = "$ext files are removed"
        }
        if ($config.RemoveMode -eq 'Holding') {
            # One Holding subfolder per day, so cleanup can go by folder date
            $destLabel   = "Holding/$runDay"
            $destination = Join-Path (Join-Path $holdingPath $runDay) $File.Name
            $reason      = "$removeText -> $destLabel"
        }
        else {
            $reason = "$removeText -> deleted"
        }
    }
    else {
        $homeFolder = Get-HomeFolder $ext
        if ($null -eq $homeFolder) {
            $reason = "no filing rule for $ext files"
        }
        elseif ($homeFolder -ne $Folder) {
            # Build the path one part at a time, so 'Models/Stray FitFoot Files' works on Windows too
            $homePath = $rootPath
            foreach ($part in ($homeFolder -split '/')) {
                $homePath = Join-Path $homePath $part
            }
            $action      = 'Move'
            $destLabel   = $homeFolder
            $destination = Join-Path $homePath $File.Name
            $reason      = "$ext files belong in $homeFolder"
        }
        elseif ($null -ne $config.HandSortSubfolders.$ext) {
            # In its home folder but loose at the top, e.g. a .pim that belongs in a machine subfolder.
            # Only a person knows which subfolder, so it is never moved or archived.
            $choices = @($config.HandSortSubfolders.$ext) | ForEach-Object { "$Folder/$_" }
            $reason  = "$ext files belong in $($choices -join ' or '): sort it by hand"
        }
        elseif ($ageDays -gt $config.ArchiveAfterDays) {
            # Ben's layout: Archive\<Year>\<Folder>\<Month>\, e.g. 2026\Scans\09 Sep.
            # Year and month come from the file's newest date, i.e. when the work was done.
            $year        = $newest.ToString('yyyy')
            $month       = $newest.ToString('MM')
            $monthFolder = Get-ArchiveMonthFolder -Year $year -Folder $Folder -Date $newest
            if ($null -eq $monthFolder) {
                # Archive folders are only ever made by people, so stop here and ask
                $reason = "$ageDays days old, but there is no archive folder for Archive/$year/$Folder/$month"
            }
            else {
                $archiveFolder = Join-Path (Join-Path (Join-Path $archivePath $year) $Folder) $monthFolder
                $action      = 'Archive'
                $destLabel   = "Archive/$year/$Folder/$monthFolder"
                $destination = Join-Path $archiveFolder $File.Name
                $reason      = "$ageDays days old -> $destLabel"
            }
        }
        else {
            $action = 'Leave'
            $reason = "$ageDays days old"
        }
    }

    # Never overwrite: if a file with this name is already at the destination, review instead
    if (($null -ne $destination) -and (Test-Path -LiteralPath $destination)) {
        $reason      = "$action blocked: a file with the same name is already in $destLabel"
        $action      = 'Review'
        $destination = $null
    }

    [pscustomobject]@{
        Folder      = $Folder
        Name        = $File.Name
        AgeDays     = $ageDays
        Action      = $action
        Source      = $File.FullName
        Destination = $destination
        Reason      = $reason
    }
}

$results = @()
foreach ($folder in $config.Folders) {
    $folderPath = Join-Path $rootPath $folder
    # -File lists files only, and without -Recurse subfolders are never entered
    $files = Get-ChildItem -LiteralPath $folderPath -File |
        Where-Object { -not (Test-IgnoredName $_.Name) }
    foreach ($file in $files) {
        $results += Get-FileAction -File $file -Folder $folder
    }
}

# --- Holding cleanup: files in date folders older than HoldingDays are purged ---
$expiredFolders = @()
foreach ($item in (Get-ChildItem -LiteralPath $holdingPath)) {
    # Only folders named like 2026-11-02 count; TryParseExact fills $folderDate when it matches
    $folderDate   = [datetime]::MinValue
    $isDateFolder = $item.PSIsContainer -and [datetime]::TryParseExact(
        $item.Name, 'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$folderDate)

    if (-not $isDateFolder) {
        $results += [pscustomobject]@{
            Folder      = 'Holding'
            Name        = $item.Name
            AgeDays     = $null
            Action      = 'Review'
            Source      = $item.FullName
            Destination = $null
            Reason      = 'only dated folders belong in Holding'
        }
        continue
    }

    $daysHeld = ($runStart.Date - $folderDate).Days
    if ($daysHeld -le $config.HoldingDays) {
        continue
    }

    $expiredFolders += $item.FullName
    # -Force includes hidden files, so nothing is left behind to keep the folder alive
    foreach ($file in (Get-ChildItem -LiteralPath $item.FullName -File -Force)) {
        $results += [pscustomobject]@{
            Folder      = "Holding/$($item.Name)"
            Name        = $file.Name
            AgeDays     = $daysHeld
            Action      = 'Purge'
            Source      = $file.FullName
            Destination = $null
            Reason      = "in Holding for $daysHeld days"
        }
    }
}

$results | Format-Table Folder, Name, AgeDays, Action, Reason -AutoSize -Wrap

Write-Host "Summary:"
foreach ($group in ($results | Group-Object Action)) {
    Write-Host "  $($group.Name): $($group.Count)"
}

if (-not $Apply) {
    Write-Host "Dry run: nothing was changed. Run again with -Apply to make these changes."
    exit 0
}

# --- Apply the actions, writing each one to the journal ---
$journalFile = Join-Path $journalPath "$runId.csv"
$toDo        = $results | Where-Object { @('Move', 'Archive', 'Remove', 'Purge') -contains $_.Action }
$reviews     = $results | Where-Object { $_.Action -eq 'Review' }
$failed      = 0

# Adds one row to this run's journal. Every row has the same columns.
function Write-JournalRow {
    param(
        [string]$Action,
        [string]$Source,
        [string]$Destination,
        [string]$Result,
        [string]$Reason,
        [string]$ErrorText
    )
    [pscustomobject]@{
        RunId       = $runId
        Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Action      = $Action
        Source      = $Source
        Destination = $Destination
        Result      = $Result
        Reason      = $Reason
        Error       = $ErrorText
    } | Export-Csv -LiteralPath $journalFile -Append -NoTypeInformation -Encoding UTF8
}

foreach ($item in $toDo) {
    $outcome   = 'Done'
    $errorText = ''
    try {
        if ($null -eq $item.Destination) {
            # Purge, or Remove with RemoveMode 'Delete': there is nowhere to move it.
            # -Force lets it delete hidden and read-only files too.
            Remove-Item -LiteralPath $item.Source -Force -ErrorAction Stop
        }
        else {
            $destFolder = Split-Path -Path $item.Destination -Parent
            if (-not (Test-Path -LiteralPath $destFolder)) {
                if ($item.Action -eq 'Archive') {
                    # Archive folders are never created by the filer, even if one vanished since the check
                    throw "The archive folder no longer exists: $destFolder"
                }
                New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
            }
            # Without -Force, Move-Item refuses to overwrite an existing file
            Move-Item -LiteralPath $item.Source -Destination $item.Destination -ErrorAction Stop
        }
    }
    catch {
        $outcome   = 'Failed'
        $errorText = $_.Exception.Message
        $failed++
    }

    # Written straight after each action, so a crash part-way still leaves a full record
    Write-JournalRow -Action $item.Action -Source $item.Source -Destination $item.Destination `
                     -Result $outcome -Reason $item.Reason -ErrorText $errorText

    Write-Host "  $outcome  $($item.Action)  $($item.Name)"
}

# The review list goes in the journal too, so the morning report can show it
foreach ($item in $reviews) {
    Write-JournalRow -Action 'Review' -Source $item.Source -Destination '' `
                     -Result 'Review' -Reason $item.Reason -ErrorText ''
}

# A quiet night still leaves a journal, so "nothing to do" can't be mistaken for "didn't run"
if ((@($toDo).Count + @($reviews).Count) -eq 0) {
    Write-JournalRow -Action 'Run' -Source '' -Destination '' `
                     -Result 'NothingToDo' -Reason 'no files needed any action' -ErrorText ''
}

# Expired Holding date folders are removed once their files are gone
foreach ($expired in $expiredFolders) {
    if (@(Get-ChildItem -LiteralPath $expired -Force).Count -eq 0) {
        Remove-Item -LiteralPath $expired
        Write-Host "  Removed empty folder $expired"
    }
    else {
        Write-Host "  Left $expired in place: it still has something in it"
    }
}

$toDoCount = @($toDo).Count
if ($toDoCount -eq 0) {
    Write-Host "Nothing to do."
}
else {
    Write-Host "Applied $($toDoCount - $failed) of $toDoCount action(s). Journal: $journalFile"
}

if ($failed -gt 0) {
    Write-Host "$failed action(s) failed. See the Error column in the journal."
    exit 1
}
