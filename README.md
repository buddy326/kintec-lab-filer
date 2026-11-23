# kintec-lab-filer

A nightly PowerShell script that tidies the CAD file store in Kintec's lab. It runs on lab machine **CAD4** and tidies all four folders (`Scans`, `Models`, `Mill Jobs`, `NC Programs`). It moves misfiled files into the correct folder, archives finished work, and removes junk. Windows Task Scheduler runs it every night at **2am**, after the lab's last work (sometimes as late as 1am) and before the morning.

This repo is being built and tested on a Mac (M1, PowerShell 7) against a fake copy of the lab folders (`Cad4Sim/`). Windows-only behaviour (Task Scheduler, NTFS dates, FreeFileSync, file locks) gets tested later in a Windows 11 ARM VM.

---

## How we work on this

- **Step by step.** One small piece at a time. Explain what each piece of code does before moving on. Don't generate the whole project in one go.
- **The developer is learning PowerShell.** Explain new syntax and cmdlets when they first appear.
- **Rules live in a config file, not in code.** Rules will change as Ben (the lab contact) answers questions by email. Folder paths, the extension-to-folder table, thresholds and removal lists go in a JSON config. The classification logic stays in code.

---

## Must-follow rules for all code

1. **Windows PowerShell 5.1 compatible.** CAD4 (Windows 11) runs 5.1 out of the box, not 7 (to confirm). Don't use 7-only syntax: no `??`, no `?:` ternary, no `&&` / `||` between commands, no `ForEach-Object -Parallel`, and no `-AsHashtable` on `ConvertFrom-Json`.
2. **No hard-coded paths.** Build every path with `Join-Path` from the config or a parameter. Nothing like `/Users/...` or `C:\...` in the logic.
3. **Top level only.** The script lists only the files directly inside the four folders below. It never goes into subfolders and never touches anything outside the four folders. That's an allowlist, not an exclusion list.
4. **Never lose a file.** Every action is written to a journal. Moves can be undone. "Removed" files go to a holding folder first (deleting outright is a config setting).
5. **No real patient names** anywhere in the repo. Test data uses made-up names only. `Cad4Sim/` is git-ignored.
6. **Dry run first.** The script must support a mode that reports what it would do without changing anything.

---

## Repo layout

```
kintec-lab-filer/
├── README.md
├── .gitignore              # contains: Cad4Sim/ (not added yet)
├── config.json             # filing rules, paths and thresholds
├── scripts/
│   ├── New-TestData.ps1    # builds the fake CAD4 tree (done)
│   ├── LabFiler.Common.ps1 # shared helpers, dot-sourced by the scripts
│   ├── Invoke-LabFiler.ps1 # the filer: dry run by default, -Apply to make changes
│   ├── Undo-LabFilerRun.ps1 # reverses one run from its journal
│   └── New-MorningReport.ps1 # turns a run's journal into an HTML + PDF report
└── Cad4Sim/                # fake CAD4 data, generated, git-ignored
    ├── OrthoModelData/
    │   ├── Scans/
    │   │   └── Cropper Originals/   # subfolder: must never be touched
    │   ├── Models/
    │   │   ├── Ben - Dev/           # permanent subfolder: never touched
    │   │   └── USB Drive/           # permanent subfolder: never touched
    │   ├── Mill Jobs/
    │   └── NC Programs/
    │       ├── Lincoln/             # mill subfolder: .pim files go here (by hand)
    │       ├── Obama/               # mill subfolder: .pim files go here (by hand)
    │       └── Manual CNC/          # stays, never touched
    ├── Archive/            # stands in for the archive share
    ├── Holding/            # removed files wait here 14 days, in Holding/<YYYY-MM-DD>/
    ├── Journal/            # one CSV per run: <RunId>.csv
    └── Reports/
        ├── Today's Report/      # only the newest PDF
        └── Archived Reports/    # every earlier PDF
```

On the real system, `Models` has six permanent subfolders: `Alex FitFootImport`, `Ben - Dev`, `Foot Forward FF Case Files`, `Matt FF360 Import`, `Texture Insole`, `USB Drive`. The sim includes two of them as decoys.

---

## Filing rules (current, will grow)

Each extension has one **home folder**. A file found in any of the other three folders moves to its home.

| Extension | Home folder |
|---|---|
| `.stl`, `.dmt`, `.jpg` / `.jpeg` | `Scans` |
| `.ort` | `Models` |
| `.ortmill` | `Mill Jobs` |
| `.pim` | `NC Programs`, but really its `Lincoln` or `Obama` mill subfolder. A `.pim` is the G-code Orthomill writes for the CNC mill, saved next to the `.ortmill` project at 500 to 1,000 KB each. A `.pim` found elsewhere moves to `NC Programs`. One loose at the top of `NC Programs` goes on the review list, because only a person knows which mill it's for (`HandSortSubfolders`). It's never archived. |
| `.ff*` (any `.FF…` extension) | `Models/Stray FitFoot Files` (per Ben, to see what turns up before deciding) |
| `.zip` | none: removed from any of the four folders |
| `.pdf` in `NC Programs` | none: block-map PDFs (printed maps of the milling block), which Ben says can be deleted. Removed from that folder only (`RemoveByFolder`). A `.pdf` anywhere else goes on the review list. |

`.ort` files in `NC Programs` "definitely should not be in here" (Ben) and move to `Models` under the normal `.ort` rule. `.nc` has no rule.

**Nothing is archived from `NC Programs`** (decision, 2026-11-15). This already holds with the current rules:
- loose `.pim` files go on the review list, never the archive;
- the `Lincoln` / `Obama` subfolders where `.pim` files belong are never entered.

Ben's archive has a `[Year]\NC Programs\Lincoln|Obama\[Month]\` layout, but the filer doesn't fill it. If a future rule gives another extension `NC Programs` as its home, add an explicit "never archive" check for `NC Programs` at the same time.

General rules:
- **The extension** decides where a file goes. Match extensions case-insensitively (`.STL` = `.stl`).
- **Any extension not in the table** goes on the **review list** and isn't touched.
- **Wildcard rules** like `.ff*` apply only when no exact rule matches.
- **All four folders are tidied on CAD4, at 2am.** `Mill Jobs` and `NC Programs` sync two ways between CAD5 and CAD4 (Ben is setting it up), so the filer's changes on CAD4 carry over to CAD5.
- **Never touched or reported:** names matching `IgnorePatterns` (`*.ffs_db`, `*.ffs_lock`, `*.ffs_tmp`). These are FreeFileSync's own sync database, lock and temp files, which also match `.ff*`. Moving `sync.ffs_db` would make a Two-way job lose its sync record.
- **Name collisions:** if a file with the same name already exists at the destination (move, archive or `Holding`), nothing is overwritten. The file stays where it is and goes on the review list.
- **ZIPs are removed.** Ben wants them deleted. The default is to move them to `Holding`, with outright delete as a config setting.
- **Holding cleanup:** removed files go into a dated subfolder, `Holding/<YYYY-MM-DD>/`, named after the day they were removed. A date folder more than **14 days** old is deleted, and each delete is journaled. The clock goes by the folder date, not the file's own dates: a move keeps the old dates, so a 90-day-old ZIP would otherwise be deleted the very next night. Dated folders also stop the same ZIP name removed on different days from colliding. The 14 days is a config setting.
- **Archive:** a file in the right folder that is **older than 14 days** moves to `Archive/<YYYY>/<Folder>/<MM Mon>/`, e.g. `2026/Scans/09 Sep/`. This is Ben's layout.
  - **Which archive:** there are two, both shared from CAD4 and split by date: `\\wks-lab-cad4\Archive 2012-2021` (`E:\Archive 2012-2021\` on CAD4) and `\\wks-lab-cad4\Archive 2022-Current` (`D:\` on CAD4). Everything archived now is from 2022 or later, and the filer runs on CAD4, so the real `ArchivePath` is the local `D:\`. The 2012–2021 archive is never touched.
  - **Month folders:** Ben names them `01 Jan`, `02 Feb` and so on, and only the number matters. An existing folder whose name starts with the month number (`09 Sep`, `09 September`, `09`) is used. If two match, the first alphabetically is used.
  - **The filer never creates archive folders.** If the year, folder or month folder doesn't exist, the file goes on the review list ("no archive folder for Archive/2026/Scans/10"). If a folder vanishes between the check and the move, the archive is recorded as `Failed` instead of the folder being recreated. This last case is untested. So each month's folders must be made by hand before files can be archived into them.
  - **Cross-drive moves:** the archive is local, but if the four folders aren't on `D:` too, each archive move is a copy-then-delete between drives rather than an instant rename.
  - **Ben's `NC Programs\Lincoln|Obama\[Month]` layout** isn't used, because nothing is archived from `NC Programs`.
- **Age = newest of modified date and created date.** Using the newest date protects current work that carries one old date (repeat-order scans, models copied back). Order-number parsing as a third date is skipped for now (see Next steps).
- FitFoot hard-print `.stl` files are **out of scope for now**. All `.stl` is treated as a scan.

### Filename patterns (for later, when we parse order numbers)
- Current: `423083 - Jane Doe - D K1T.ort` (six-digit order number, name, product code)
- Typo: `43028 - Dana Fox A1M.ort` (five digits on current work, which happens weekly)
- Old (around 2014): `32123 - Z1208JL-RL.ort`
- Odd: `001 (421511JaneDoe) .ort`
- Every `T1C` file has a **trailing space** before the extension: `423107 - Grace Kim - T1C .ort`
- Scans on the real share are named by scan date and number, not order number: `Scan-2026-11-05-535...`
- On the real share, many files have a created date **later** than their modified date (copied files keep the old modified date), and some `Models` files were modified years before they were created. That's why age uses the newer of the two.
- Product codes like `A1M`, `K1T` are technician initials and don't affect filing.

---

## Done so far

1. Installed PowerShell 7 (`pwsh`) on the Mac via Microsoft's `.pkg`, plus VS Code with the Microsoft PowerShell extension.
2. Created the repo with `scripts/` and `Cad4Sim/`, and git-ignored `Cad4Sim/`.
3. Wrote `scripts/New-TestData.ps1`:
   - `-Path` defaults to `../Cad4Sim` relative to the script (`$PSScriptRoot`).
   - `-Reset` deletes and rebuilds `Cad4Sim` so every test starts from the same state.
   - The `New-SimFile` helper creates a file and backdates its created and modified dates by N days.
   - Creates 21 test files. Each line has a comment with the expected outcome (the answer key).
4. Ran it and confirmed backdated **creation** and **modified** dates both stick on macOS.
5. Wrote `config.json`. Relative paths in it are resolved against the folder holding the config file. JSON allows no comments, and 5.1 rejects them.
6. Wrote `scripts/Invoke-LabFiler.ps1` startup validation (`-ConfigPath` defaults to `../config.json`). It collects every problem, prints them all and exits with code 1. It checks:
   - every setting is present
   - every folder exists
   - extensions start with a dot
   - every `HomeFolders` target is in `Folders`
   - no extension is both filed and removed
   - `RemoveMode` is `Holding` or `Delete`
   - the day counts are whole numbers of 1 or more
7. Added read-only classification to `Invoke-LabFiler.ps1`. It prints each top-level file in the four folders with its action (`Leave`, `Move`, `Archive`, `Remove`, `Review`) and a reason, then a summary. It matches the answer key. Decisions:
   - A misfiled file moves to its home folder even if it's old. It gets archived from there on a later night.
   - Archive month = the month of the file's newest date (when the work was done), not the run date.
   - Hidden files (e.g. `Thumbs.db`, `desktop.ini` on Windows) are skipped, because `Get-ChildItem` without `-Force` doesn't list them.
8. Added the journal and real actions:
   - **Dry run is the default.** Nothing changes unless `-Apply` is passed, and the scheduled task will pass it.
   - **Journal:** each run writes `Journal/<RunId>.csv` (RunId = start time, `yyyyMMdd-HHmmss`) with the columns RunId, Time, Action, Source, Destination, Result, Error. Each row is written straight after its action.
   - **Failures don't stop the run.** A failed action (e.g. a locked file) is recorded as `Failed` with the error, the run continues, and the script exits with code 1.
   - `Move-Item` without `-Force` never overwrites, which backs up the collision check.
   - Tested: dry run changes nothing; apply matches the answer key; a second apply does nothing; read-only `Scans` gives `Failed` rows and exit 1; `Delete` mode deletes the ZIPs.

9. Added Holding cleanup:
   - **Purge:** files in a `Holding/<YYYY-MM-DD>/` folder more than `HoldingDays` old are deleted. Each one is a `Purge` action, shown in the dry run and journaled like every other action. The folder is removed once it's empty, or left in place and reported if anything is still in it.
   - **Review:** anything else in `Holding` (loose files, folders not named as dates) goes on the review list.
   - **Tested:** the test data now includes Holding cases, including the exact-14-day edge.

10. Wrote `scripts/Undo-LabFilerRun.ps1`:
    - **What it reverses:** it reads `Journal/<RunId>.csv` and, last action first, moves each `Done` file from `Destination` back to `Source`.
    - **Dry run by default:** it changes nothing unless `-Apply` is passed.
    - **What it skips:** purges and `Delete`-mode removes (the file is gone), failed actions, files no longer at their destination, and anything whose original place is occupied. It never overwrites.
    - **Its own journal:** `Journal/undo-<timestamp>.csv`, with the same columns, so an undo can be undone too.
    - **Empty folders:** folders left empty in `Archive` stay where they are. An empty `Holding` date folder gets removed by cleanup once it expires.
    - **Tested:**
      - undo restores everything except purged files;
      - running it twice does nothing;
      - undoing the undo gives back the exact post-run state;
      - an unknown run ID exits with code 1.

11. Wrote `scripts/New-MorningReport.ps1` (email still to do):
    - **Journal changes:** it now has a `Reason` column. It also records review items (`Result = Review`), and on a quiet night it writes one `Run` / `NothingToDo` row, so "nothing to do" is distinguishable from "didn't run".
    - **Which run:** the report reads the newest filer journal (undo journals are ignored), or `-RunId`.
    - **Output:** the report is a PDF named `File tidy-up <YYYY-MM-DD> <HHmm>.pdf`. The page is built as HTML in the temp folder, printed to PDF with a Chromium browser in headless mode, and the HTML is then deleted. If no PDF can be made, the HTML is saved in its place and the script exits with code 1.
    - **Folders:** the report goes in `<ReportPath>/Today's Report/`, and whatever was there moves to `Archived Reports/` first, so `Today's Report` only ever holds the newest report. A report rebuilt with `-RunId` goes straight to `Archived Reports/`. The folder names are the `ReportTodayFolder` and `ReportArchiveFolder` settings. Ben reads the reports from this folder, instead of getting them by email.
    - **Layout:**
      - a status line ("Nothing needs your attention" / "N item(s) need your attention");
      - counts;
      - sections: Could not be done, Needs a person to look at, Moved, Archived, Removed, Deleted from Holding.

      Folders are shown short (`Scans`, `Archive/2026/Scans/09 Sep`), and raw errors are turned into plain English. Empty sections are left out.
    - **Stale warning:** if the newest run is more than 24 hours old, the report says last night's run may not have happened.
    - **Config:**
      - `ReportPath`;
      - `PdfBrowserPath`. On CAD4 this is Edge, `"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"`; the sim config points at Chrome on the Mac. If it's blank, only the HTML is made.
    - **Tested:** normal, failure, quiet and stale runs. Undo still works with the new journal rows.
    - **Fixed bug:** a plain `[System.Uri]` cast of a path makes a *relative*, empty address on macOS. The browser then printed its new-tab page instead of the report. The address is now built with `UriKind Absolute`, and the script stops with an error if it's still empty. Check the PDF itself, not just the HTML: on the Mac, `qlmanage -t <file.pdf>` renders a preview image.
    - **macOS quirk:** a failed move can leave a copy at the destination while the original stays put, because .NET on Unix links first and then unlinks. Nothing is lost, and the next night flags it as a name collision. A same-drive move on Windows is atomic. Moves to the archive on another drive are copy-then-delete, though, so the VM test must check what a locked file does there.

```powershell
./scripts/Invoke-LabFiler.ps1                               # dry run
./scripts/Invoke-LabFiler.ps1 -Apply                        # make the changes
./scripts/Undo-LabFilerRun.ps1 -RunId 20261102-220323       # dry run of an undo
./scripts/Undo-LabFilerRun.ps1 -RunId 20261102-220323 -Apply
./scripts/New-MorningReport.ps1                             # report on the newest run
```

Run it with:
```powershell
./scripts/New-TestData.ps1 -Reset
```

### Test files and expected outcomes

| Folder | File | Days old | Expected |
|---|---|---|---|
| Scans | `423101 - Jane Doe L.stl` | 2 | leave |
| Scans | `423101 - Jane Doe R.stl` | 2 | leave |
| Scans | `421877 - Sam Poe L.stl` | 45 | review list (no archive folder for its month) |
| Scans | `Scan-2026-01-10-500001.stl` | created 60, modified 3 | leave (newer date counts) |
| Models | `118300 - Copied Back - A1M.ort` | created 2, modified ~3200 | leave (copied in recently, old modified date) |
| Models | `118301 - Both Old - A1M.ort` | created 60, modified ~3200 | archive (into the existing month folder) |
| Scans | `423102 - Alex Roe.dmt` | 3 | leave |
| Scans | `423102 - Alex Roe L.jpg` | 3 | leave |
| Scans | `423103 - Kim Park - A1M.ort` | 1 | move → Models |
| Scans | `423104 - Liam Walsh.zip` | 5 | remove |
| Scans | `Foot Rx 423105.pdf` | 2 | review list |
| Scans/Cropper Originals | `old batch.zip` | 90 | **untouched** (subfolder) |
| Models | `423106 - Nora Quinn - D K1T.ort` | 4 | leave |
| Models | `423107 - Grace Kim - T1C .ort` | 6 | leave (trailing space) |
| Models | `420950 - Omar Haddad - A1M.ort` | 60 | archive |
| Models | `43028 - Dana Fox A1M.ort` | 3 | leave |
| Models | `423108 - Eli Grant R.stl` | 2 | move → Scans |
| Models | `423109 - Mia Torres.ortmill` | 1 | move → Mill Jobs |
| Models | `423114 - Ana Ruiz.ffp` | 3 | move → Models/Stray FitFoot Files |
| Models | `sync.ffs_db` | 1 | **untouched**, not listed (FreeFileSync) |
| Scans | `423113 - Lee Chan.FFP` | 2 | move → Models/Stray FitFoot Files |
| Scans | `sync.ffs_db` | 1 | **untouched**, not listed (FreeFileSync) |
| Models | `export backup.zip` | 10 | remove |
| Models/Ben - Dev | `test insole.ort` | 200 | **untouched** (subfolder) |
| Mill Jobs | `423110 - Owen Park.ortmill` | 1 | leave |
| Mill Jobs | `423111 - Zoe Hart - A1M.ort` | 2 | move → Models |
| Archive/<year>/Models | `<MM> existing/` (folder, for the month 60 days ago) | — | used for both 60-day-old `Models` files, found by its month number |
| Mill Jobs | `421500 - Ivy Long.ortmill` | 40 | review list (no archive folder) |
| Mill Jobs | `mill export.zip` | 5 | remove |
| NC Programs | `423112 - Ruth Ellis L.PIM` | 1 | review list (which mill?) |
| NC Programs | `420800 - Paul Reid.pim` | 40 | review list (never archived) |
| NC Programs | `423112 - Ruth Ellis.PDF` | 2 | remove (block-map `.pdf`) |
| NC Programs | `423116 - Ben Ito - A1M.ort` | 3 | move → Models |
| NC Programs | `old program.nc` | 5 | review list (no rule) |
| NC Programs/Lincoln, Obama, Manual CNC | one `.pim` each | 2–300 | **untouched** (subfolders) |
| Mill Jobs | `423117 - Kai Moss.pim` | 1 | move → NC Programs (review list the next night) |
| OrthoModelData (root) | `notes.txt` | 30 | **untouched** (outside scope) |
| Holding/<today − 20> | `423001 - Old Job.zip` | 20 | purge, folder removed |
| Holding/<today − 15> | `423002 - Older Job.zip` | 15 | purge, folder removed |
| Holding/<today − 14> | `423003 - Edge Job.zip` | 14 | keep (exactly 14 days) |
| Holding/<today − 3> | `423004 - New Job.zip` | 3 | keep |
| Holding (root) | `loose file.zip` | 30 | review list (not in a date folder) |
| Holding (root) | `misc/` (folder) | — | review list (not a date folder) |

---

## Next steps (in order)

1. **Confirm modified dates** match created dates in the test data:
   ```powershell
   Get-ChildItem ./Cad4Sim -Recurse -File |
       Select-Object Name,
           @{n='Created';  e={ $_.CreationTime.ToString('yyyy-MM-dd') }},
           @{n='Modified'; e={ $_.LastWriteTime.ToString('yyyy-MM-dd') }} |
       Format-Table -AutoSize
   ```
2. **Config file** (`config.json`): root path, the four folders, archive and holding paths, the extension-to-folder table, removal extensions, age threshold (14 days), remove mode (`Holding` / `Delete`), holding retention (14 days).
3. **Startup validation:** stop if any configured folder doesn't exist.
4. **Classify only (read-only):** list each file in the four folders with the action it *would* get, and compare against the answer key above.
5. **Journal plus dry run**, then real moves.
6. **Holding cleanup:** delete `Holding/<YYYY-MM-DD>/` folders more than 14 days old, journaling each delete.
7. **Undo script** that reverses a run by run ID from the journal.
8. **Morning report:** done. The PDF goes into a `Today's Report` folder for Ben (see Done so far), instead of being emailed. Email can be added later if Kintec's mail system allows it.
9. ~~**Order-number parsing** as the third date in the age rule.~~ Skipped for now. Age stays the newest of created and modified date. Known risk: a current file that arrives with old dates on both (moved in, or copied back with dates kept) gets archived the next night. It can be brought back with the undo script.
10. **Windows VM testing:** PowerShell 5.1, Task Scheduler setup script, NTFS dates, file locks, FreeFileSync behaviour.

---

## Open questions (don't block the build)

- ~~What file types live in `NC Programs`?~~ Answered by Ben: `.pim` (in the `Lincoln` / `Obama` subfolders). Stray `.ort` files move to `Models`, and block-map `.pdf` files are deleted.
- ~~FreeFileSync direction on the workstations.~~ Answered by Ben: the jobs are all Two-way or Mirror (CAD4 → workstation), never Mirror plus Update.
  - Both pass CAD4's moves and deletions on, so archived files don't come back. That makes it safe to run against the real `Scans` and `Models`.
  - Edge case: if a Two-way job loses its `sync.ffs_db`, it could copy an archived file back. The next night that file collides with its copy in `Archive` and goes on the review list, so nothing is lost.
- ~~Which machine runs the filer, and when?~~ Answered by Ben: CAD4, at 2am. `Mill Jobs` / `NC Programs` will sync two ways between CAD5 and CAD4.
- **Where do the four folders live on CAD4?** The local path (behind the `Z:` share) is needed for `RootPath`. The config has one `RootPath` for all four folders, which only works if they all sit under one parent folder.
- Which Windows account runs the scheduled task?
- Morning report folder: where should `ReportPath` be, so Ben can open it from his own computer (e.g. a folder on the `Z:` share)? The account that runs the nightly task needs write access to it.
- Can the report show patient names (they're in the filenames), or should it show order numbers only?