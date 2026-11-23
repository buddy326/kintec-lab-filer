param(
    [string]$Path = (Join-Path $PSScriptRoot '../Cad4Sim'),
    [switch]$Reset
)

# Start fresh if asked, so every test run begins from the same state
if ($Reset -and (Test-Path $Path)) {
    Remove-Item -Path $Path -Recurse -Force
    Write-Host "Wiped $Path"
}

$folders = @(
    'OrthoModelData/Scans',
    'OrthoModelData/Scans/Cropper Originals',
    'OrthoModelData/Models',
    'OrthoModelData/Models/Ben - Dev',
    'OrthoModelData/Models/USB Drive',
    'OrthoModelData/Mill Jobs',
    'OrthoModelData/NC Programs',
    'OrthoModelData/NC Programs/Lincoln',
    'OrthoModelData/NC Programs/Obama',
    'OrthoModelData/NC Programs/Manual CNC',
    'Archive',
    'Holding',
    'Journal'
)

foreach ($f in $folders) {
    New-Item -ItemType Directory -Path (Join-Path $Path $f) -Force | Out-Null
}

# Makes one fake file, then backdates it by $DaysOld days.
# -ModifiedDaysOld gives the modified date a different age (e.g. a copied file keeps an old one).
function New-SimFile {
    param(
        [string]$Folder,
        [string]$Name,
        [int]$DaysOld,
        [int]$ModifiedDaysOld = -1
    )
    if ($ModifiedDaysOld -lt 0) {
        $ModifiedDaysOld = $DaysOld
    }
    $file = Join-Path (Join-Path $Path $Folder) $Name
    Set-Content -Path $file -Value "fake content for $Name"
    # Modified first: macOS drags the created date back if modified is set earlier than it
    (Get-Item $file).LastWriteTime = (Get-Date).AddDays(-$ModifiedDaysOld)
    (Get-Item $file).CreationTime  = (Get-Date).AddDays(-$DaysOld)
}

$S = 'OrthoModelData/Scans'
$M = 'OrthoModelData/Models'
$J = 'OrthoModelData/Mill Jobs'
$N = 'OrthoModelData/NC Programs'

# --- Scans ---
New-SimFile $S '423101 - Jane Doe L.stl'          2    # right place, recent  -> leave
New-SimFile $S '423101 - Jane Doe R.stl'          2    # right place, recent  -> leave
New-SimFile $S '421877 - Sam Poe L.stl'           45   # right place, old, no archive folder for its month -> review list
# Mixed dates, as seen on the real share: age goes by the newer of the two
New-SimFile $S 'Scan-2026-01-10-500001.stl'       60 -ModifiedDaysOld 3      # edited 3 days ago -> leave
New-SimFile $M '118300 - Copied Back - A1M.ort'   2  -ModifiedDaysOld 3200   # copied in 2 days ago, modified ~2017 -> leave
New-SimFile $M '118301 - Both Old - A1M.ort'      60 -ModifiedDaysOld 3200   # both dates old    -> archive (existing folder)
New-SimFile $S '423102 - Alex Roe.dmt'            3    # right place, recent  -> leave
New-SimFile $S '423102 - Alex Roe L.jpg'          3    # right place, recent  -> leave
New-SimFile $S '423103 - Kim Park - A1M.ort'      1    # wrong folder         -> move to Models
New-SimFile $S '423104 - Liam Walsh.zip'          5    # zip                  -> remove
New-SimFile $S 'Foot Rx 423105.pdf'               2    # no rule yet          -> review list
New-SimFile "$S/Cropper Originals" 'old batch.zip' 90  # subfolder            -> must NOT be touched

# --- Models ---
New-SimFile $M '423106 - Nora Quinn - D K1T.ort'  4    # right place, recent  -> leave
New-SimFile $M '423107 - Grace Kim - T1C .ort'    6    # trailing space, recent -> leave
New-SimFile $M '420950 - Omar Haddad - A1M.ort'   60   # right place, old     -> archive
New-SimFile $M '43028 - Dana Fox A1M.ort'         3    # typo order number    -> leave (dates only for now)
New-SimFile $M '423108 - Eli Grant R.stl'         2    # wrong folder         -> move to Scans
New-SimFile $M '423109 - Mia Torres.ortmill'      1    # wrong folder         -> move to Mill Jobs
New-SimFile $M 'export backup.zip'                10   # zip                  -> remove
New-SimFile "$M/Ben - Dev" 'test insole.ort'      200  # subfolder            -> must NOT be touched

# --- Mill Jobs ---
New-SimFile $J '423110 - Owen Park.ortmill'       1    # right place          -> leave
New-SimFile $J '423111 - Zoe Hart - A1M.ort'      2    # wrong folder         -> move to Models
New-SimFile $J '421500 - Ivy Long.ortmill'        40   # right place, old, no archive folder -> review list
New-SimFile $J 'mill export.zip'                  5    # zip                  -> remove

# --- Stray FitFoot files and FreeFileSync's own files ---
New-SimFile $S '423113 - Lee Chan.FFP'            2    # .FF*                 -> move to Models/Stray FitFoot Files
New-SimFile $M '423114 - Ana Ruiz.ffp'            3    # .FF*                 -> move to Models/Stray FitFoot Files
New-SimFile $S 'sync.ffs_db'                      1    # FreeFileSync database -> must NOT be touched or listed
New-SimFile $M 'sync.ffs_db'                      1    # FreeFileSync database -> must NOT be touched or listed

# --- NC Programs ---
New-SimFile $N '423112 - Ruth Ellis L.PIM'        1    # loose at top, machine unknown -> review list
New-SimFile $N '420800 - Paul Reid.pim'           40   # loose at top, old    -> review list (never archived)
New-SimFile $N '423112 - Ruth Ellis.PDF'          2    # block-map .pdf       -> remove (only in this folder)
New-SimFile $N '423116 - Ben Ito - A1M.ort'       3    # design file          -> move to Models
New-SimFile $N 'old program.nc'                   5    # no rule              -> review list
New-SimFile "$N/Lincoln" '423090 - Ada Cole.pim'  2    # subfolder            -> must NOT be touched
New-SimFile "$N/Obama" '419000 - Max Hill.pim'    90   # subfolder            -> must NOT be touched
New-SimFile "$N/Manual CNC" 'jig.pim'             300  # subfolder            -> must NOT be touched

# --- .pim outside NC Programs ---
New-SimFile $J '423117 - Kai Moss.pim'            1    # wrong folder         -> move to NC Programs (then review)

# --- OrthoModelData root ---
New-SimFile 'OrthoModelData' 'notes.txt'          30   # outside the 4 folders -> must NOT be touched

# --- Archive: a month folder that already exists ---
# Named '<MM> existing' on purpose: the filer must find it by its number, not by the full name.
# The two 60-day-old Models files should be archived into it. Every other old file has no
# archive folder for its month, so it goes on the review list (the filer never creates them).
$oldDate = (Get-Date).AddDays(-60)
$existingMonth = 'Archive/' + $oldDate.ToString('yyyy') + '/Models/' + $oldDate.ToString('MM') + ' existing'
New-Item -ItemType Directory -Path (Join-Path $Path $existingMonth) -Force | Out-Null

# --- Holding ---
# Date folders are named after the day files were removed, counted back from today
function Get-HoldingFolder {
    param([int]$DaysAgo)
    $folder = 'Holding/' + (Get-Date).AddDays(-$DaysAgo).ToString('yyyy-MM-dd')
    New-Item -ItemType Directory -Path (Join-Path $Path $folder) -Force | Out-Null
    return $folder
}
New-Item -ItemType Directory -Path (Join-Path $Path 'Holding/misc') -Force | Out-Null

New-SimFile (Get-HoldingFolder 20) '423001 - Old Job.zip'   20   # held 20 days      -> purge, folder removed
New-SimFile (Get-HoldingFolder 15) '423002 - Older Job.zip' 15   # held 15 days      -> purge, folder removed
New-SimFile (Get-HoldingFolder 14) '423003 - Edge Job.zip'  14   # held exactly 14   -> keep
New-SimFile (Get-HoldingFolder 3)  '423004 - New Job.zip'   3    # held 3 days       -> keep
New-SimFile 'Holding' 'loose file.zip'                      30   # not in a date folder -> review list
                                                                 # Holding/misc (not a date) -> review list

Write-Host "Test data ready in $Path"