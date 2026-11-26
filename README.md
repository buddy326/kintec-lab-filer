# kintec-lab-filer

A nightly PowerShell script that tidies the CAD file store in Kintec's lab. It runs on lab machine **CAD4** and tidies all four folders (`Scans`, `Models`, `Mill Jobs`, `NC Programs`). It moves misfiled files into the correct folder, archives finished work, and removes junk. Windows Task Scheduler runs it every night at **2am**, after the lab's last work (sometimes as late as 1am) and before the morning.

This repo is being built and tested on a Mac (M1, PowerShell 7) against a fake copy of the lab folders (`Cad4Sim/`). Windows behaviour is tested in a Windows 11 ARM VM (UTM) running Windows PowerShell 5.1. See Done so far, item 12.

**Status (2026-11-25):** built and tested, including as a Windows scheduled task on a test VM. **Not yet installed on CAD4.** The next step is the setup below.

---

## What it does, in short

Every night at 2am, on CAD4:

1. **The filer** (`Invoke-LabFiler.ps1 -Apply`) looks at the files directly inside `Scans`, `Models`, `Mill Jobs` and `NC Programs`. It never looks in their subfolders. Each file gets one action:

   | Action | What happens |
   |---|---|
   | **Leave** | it's in the right folder and recent: nothing happens |
   | **Move** | it's in the wrong folder, so it moves to its home folder (e.g. a `.stl` in `Models` goes to `Scans`) |
   | **Archive** | it's in the right folder but more than 14 days old, so it moves to Ben's archive, `<Year>\<Folder>\<MM Mon>\` |
   | **Remove** | it's junk (`.zip` anywhere, `.pdf` in `NC Programs`), so it moves to `Holding\<date>\`, where it's deleted after 7 days |
   | **Review** | the filer isn't sure (unknown file type, no archive folder for that month, a name clash): nothing happens, and it's listed in the report for a person to look at |

2. **The journal** records every action in a CSV file, as it happens. Any night can be undone from its journal.
3. **The morning report**, a PDF, goes into a `Today's Report` folder. The previous one moves to `Archived Reports`. It says what was done and what needs a person.

**Safety:**
- **Nothing is ever overwritten.** If a file with the same name is already at the destination, the file stays put and goes on the review list.
- **The filer never creates archive folders.** It only uses the ones Ben has made.
- **Junk sits in Holding for 7 days** before it's deleted.
- **Every move can be undone.**

The rules (which extension belongs where, the day counts, what's junk) are all in `config.json`, not in the code. See [Filing rules](#filing-rules-current-will-grow) for the details.

---

## Installing on CAD4 (step by step)

This is for whoever sets it up in person. Allow about two hours with Ben, most of it for reading through the first dry run together.

**Privacy:** the dry-run output, the journals and the reports all contain **patient names**, because they're in the filenames. Keep them on CAD4. Don't email them, copy them off the machine, or add them to this repo.

### Step 0: Get answers from Ben first

These decide what goes in the config. See also [Open questions](#open-questions-dont-block-the-build).

| Question | Used for |
|---|---|
| Where are `Scans`, `Models`, `Mill Jobs` and `NC Programs` on CAD4's own drives? (Not the `Z:` share letter, but the real local path behind it, e.g. `D:\OrthoModelData`.) They must all be in **one** parent folder. | `RootPath` |
| The archive is `D:\` on CAD4 (shared as `Archive 2022-Current`). Are the year folders directly in it, i.e. `D:\2026\Scans\11 Nov\`? | `ArchivePath` |
| Where should Holding, the journal and the scripts live? Somewhere that isn't one of the four folders and isn't inside the archive's year folders, e.g. `C:\LabFiler\`. Holding on the **same drive** as the four folders makes its moves instant. | `HoldingPath`, `JournalPath` |
| Where should the reports go, so Ben can open them from his own computer (e.g. a folder on the `Z:` share)? | `ReportPath` |
| **Which Windows account** runs the nightly task? It must be a real account with a password, **not SYSTEM**, because Edge can't make the PDF under SYSTEM. Best is a dedicated account (e.g. `CAD4\labfiler`) whose password **never expires**: if the password changes, the task stops until the installer is run again. It needs read and write access to all of the folders above. | `-User` when installing |
| Are the archive month folders made for the months that need them? Files whose month folder is missing go on the review list instead of being archived. | Before the first run |

### Step 1: Check CAD4

Open **Windows PowerShell** (Start → type `powershell` → Windows PowerShell). Use PowerShell, not Command Prompt: the commands below don't work in `cmd`.

```powershell
$PSVersionTable.PSVersion          # should say 5.1
Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'   # should say True
```

If Edge is somewhere else, find `msedge.exe` and note its full path for the config.

### Step 2: Put the scripts on CAD4

Put them in the folder agreed with Ben, e.g. `C:\LabFiler\kintec-lab-filer`. Don't use your own user folder (`C:\Users\<you>\...`): the task's account may not be able to read it.

- **With git:** `cd C:\LabFiler`, then `git clone https://github.com/buddy326/kintec-lab-filer.git` (ask Aman for access).
- **Without git:** on GitHub, **Code → Download ZIP**, then extract it to `C:\LabFiler\kintec-lab-filer`. Windows marks downloaded scripts as unsafe, so unblock them:
  ```powershell
  Get-ChildItem C:\LabFiler\kintec-lab-filer -Recurse | Unblock-File
  ```

**Allow scripts to run (once per account).** Out of the box, Windows refuses to run any `.ps1` file ("running scripts is disabled on this system"). This setting, the *execution policy*, lets scripts made on this computer run, while downloaded ones still need unblocking. `-Scope CurrentUser` means it only changes your own account and doesn't need an administrator. The nightly task doesn't need it: it starts PowerShell with `-ExecutionPolicy Bypass`.

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Go into the project folder.** All the commands from here on are run from this folder (`.\scripts\...` means "the scripts folder inside the one I'm in"):

```powershell
cd C:\LabFiler\kintec-lab-filer
```

### Step 3: Create the folders the filer needs

The filer **refuses to start** if any of these are missing. That's deliberate: a typo in a path stops it, rather than files going somewhere new.

- the four folders under `RootPath` (they already exist);
- `ArchivePath` (already exists: Ben's archive);
- `HoldingPath`: make it, e.g. `New-Item -ItemType Directory C:\LabFiler\Holding`;
- `JournalPath`: make it, e.g. `New-Item -ItemType Directory C:\LabFiler\Journal`.
- any **subfolder home** in the config's `HomeFolders`. Today that's only `Models\Stray FitFoot Files`, where stray `.ff*` FitFoot files go. Check with Ben that he's happy for it to appear in `Models`, then make it, e.g. `New-Item -ItemType Directory 'D:\OrthoModelData\Models\Stray FitFoot Files'` (the quotes are needed because of the spaces).

The scripts make everything else themselves: the report folders, the month folders inside the journal, and the date folders inside Holding.

### Step 4: Write the CAD4 config

The `config.json` in the repo points at the test data (`Cad4Sim/...`). On CAD4, open it with `notepad config.json` and change the **paths** to the real ones. Leave the filing rules as they are.

```json
"RootPath":       "D:\\OrthoModelData",
"ArchivePath":    "D:\\",
"HoldingPath":    "C:\\LabFiler\\Holding",
"JournalPath":    "C:\\LabFiler\\Journal",
"ReportPath":     "D:\\OrthoModelData\\Lab Filer Reports",
"PdfBrowserPath": "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
```

These are **example paths**: use Ben's answers from step 0.

- **Every `\` must be written as `\\`.** That's how JSON writes a backslash. A single `\` makes the config fail to load.
- JSON allows no comments. Keep the quotes and commas exactly as they are.
- **Don't commit this file** back to the repo. It's CAD4's own copy. When updating the scripts later with git, use `git stash`, `git pull`, `git stash pop` to keep it. If you're using ZIPs, keep a copy of `config.json` and put it back after extracting.

### Step 5: Dry run (changes nothing)

```powershell
.\scripts\Invoke-LabFiler.ps1 *> dry-run.txt
notepad dry-run.txt
```

Without `-Apply`, the filer only reports what it **would** do. `*>` saves everything it prints into `dry-run.txt`, which may be long on the real folders.

1. **If it starts with `Config check failed`,** the lines below say what's wrong (usually a path or a missing `\\`). Fix `config.json` and run it again.
2. **Read the table through with Ben.** Look for:
   - **Archive:** are these really finished work? Is the destination month right?
   - **Move:** is each file really in the wrong folder?
   - **Remove:** is it all junk?
   - **Review with "no archive folder for ...":** Ben makes those month folders, then you dry-run again.
   - **Review with "no filing rule for .xyz":** a file type the rules don't cover. It's left alone, which is fine. If Ben wants a rule for it, add it to `HomeFolders` or `RemoveExtensions` in `config.json`.
3. Delete `dry-run.txt` afterwards, because it has patient names in it.

Repeat until Ben is happy with the plan.

### Step 6: First real run, with Ben watching

```powershell
.\scripts\Invoke-LabFiler.ps1 -Apply
.\scripts\New-MorningReport.ps1
```

- The filer ends with `Applied N of N action(s). Journal: ...`. Note the **run ID**: the start of the journal file's name, e.g. `2026-12-02_143005`.
- Open the PDF in the report folder's `Today's Report` folder and check it with Ben.
- **To reverse the whole run:**
  ```powershell
  .\scripts\Undo-LabFilerRun.ps1 -RunId 2026-12-02_143005          # shows what it would put back
  .\scripts\Undo-LabFilerRun.ps1 -RunId 2026-12-02_143005 -Apply   # puts it back
  ```
  Everything comes back except Holding files already deleted. On the first night there are none.

### Step 7: Install the nightly task

Open an **administrator** PowerShell window (right-click Windows PowerShell → **Run as administrator**), then:

```powershell
cd C:\LabFiler\kintec-lab-filer
.\scripts\Install-LabFilerTask.ps1 -User 'CAD4\labfiler'
```

- Use the account agreed with Ben. Without `-User`, the task runs as whoever is installing it, which is probably not what you want on CAD4. Run `whoami` to see how Windows writes an account name.
- It asks for that account's **Windows password** in the window (you'll see `*` as you type). A Microsoft-account sign-in needs its password, not the PIN. Windows checks it straight away and refuses a wrong one.
- It creates **Task Scheduler → Task Scheduler Library → Kintec → Lab Filer**, running daily at 2:00 AM whether anyone is logged in or not. To pick another time, add `-At '3:00 AM'`.
- Running it again replaces the task. Do that whenever the account's password changes.

### Step 8: Test the task

This is a **real run** (`-Apply`). After step 6 there's usually little left for it to do.

```powershell
Start-ScheduledTask -TaskPath '\Kintec\' -TaskName 'Lab Filer'
# wait a minute
Get-ScheduledTaskInfo -TaskPath '\Kintec\' -TaskName 'Lab Filer'
```

- `LastTaskResult : 0` means **SUCCESS**. Check that a new PDF is in `Today's Report`. (Windows only shows a number here: 0 = SUCCESS, 1 = FAILED. The nightly log spells it out in words.)
- `267009` means it's still running; wait and check again.
- `1` means something needs a look. See [Troubleshooting](#troubleshooting).

### Step 9: Check the next morning

Look for a report named for about 2:00 AM, and `LastRunTime` around 2:00 AM with `LastTaskResult : 0`. That proves it runs with nobody logged in. It's done after that.

---

## Day to day

- **Ben reads the report** in `Today's Report` each morning. "Nothing needs your attention" means there's nothing to do.
- **Review items** are left exactly where they are. Someone sorts them by hand, or adds a rule to `config.json`.
- **Archive month folders:** the filer only archives into month folders that exist. Make each month's folders (`<Year>\Scans\<MM Mon>`, `<Year>\Models\<MM Mon>`, and so on) in good time, e.g. a whole year at once. Until a folder exists, its files go on the review list every night. Nothing is lost, and they're archived the first night after the folder appears.
- **Undo a night:** find its run ID (the journal file name in `Journal\<Year>\<MM Mon>\`), then run `Undo-LabFilerRun.ps1` as in step 6.
- **Pause it** (e.g. during a migration), from an administrator window:
  ```powershell
  Disable-ScheduledTask -TaskPath '\Kintec\' -TaskName 'Lab Filer'
  Enable-ScheduledTask  -TaskPath '\Kintec\' -TaskName 'Lab Filer'
  ```
- **Remove it completely:** `.\scripts\Install-LabFilerTask.ps1 -Remove`
- **Change a rule or a day count:** edit `config.json`, then do a dry run (step 5) to check it before the next 2am run.

---

## Troubleshooting

Each night writes a log next to its journal: `Journal\<Year>\<MM Mon>\<RunId> nightly.log`. That's the first place to look.

| What you see | What it means / what to do |
|---|---|
| `LastTaskResult : 1` | **FAILED.** Open that night's `nightly.log`. It ends with `Filer: SUCCESS / FAILED`, `Report: ...` and `Overall: ...`, and the lines above say why. |
| `LastTaskResult : 267011` | The task has never run yet. |
| The report is an `.html` file, not a `.pdf` | Edge couldn't make the PDF. The log says `browser exit code: ...`. Check `PdfBrowserPath`. If the log says `running as SYSTEM: True`, re-install with a real account (step 7). |
| No log in `Journal`, but one in a `Logs` folder next to `scripts` | The config couldn't be read, or `JournalPath` doesn't exist. The log's first line says which. |
| `Config check failed` | It lists every problem: usually a folder that doesn't exist or a path missing `\\`. Nothing was changed. |
| The report says last night's run **may not have happened** | The newest run is more than a day old. CAD4 was off, or the task's password has changed (re-run step 7). Check `Get-ScheduledTaskInfo`. |
| `Failed` rows in the report | That file couldn't be moved, usually because it was open in another program. Nothing was lost, and it's tried again the next night. |
| `no archive folder for Archive/2026/Scans/10` | Make that month folder (see Day to day). |
| `running scripts is disabled on this system` | Run the `Set-ExecutionPolicy` line from step 2. If that's blocked too, run the script with `powershell -ExecutionPolicy Bypass -File .\scripts\<name>.ps1`. |
| Installer: `The user name or password is incorrect` | Check the name with `whoami` and type the password again. |
| The task won't start: "not granted the requested logon type" | The account needs the **Log on as a batch job** right: `secpol.msc` → Local Policies → User Rights Assignment. |

---

# Development notes

Everything below is the build history and design notes, for whoever changes the code.


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
├── .gitignore              # contains: Cad4Sim/, Logs/ (Logs/ only appears if the config can't be read)
├── config.json             # filing rules, paths and thresholds
├── scripts/
│   ├── New-TestData.ps1    # builds the fake CAD4 tree (done)
│   ├── LabFiler.Common.ps1 # shared helpers, dot-sourced by the scripts
│   ├── Invoke-LabFiler.ps1 # the filer: dry run by default, -Apply to make changes
│   ├── Undo-LabFilerRun.ps1 # reverses one run from its journal
│   ├── New-MorningReport.ps1 # turns a run's journal into an HTML + PDF report
│   ├── Start-LabFilerNightly.ps1 # what the 2am task runs: filer -Apply, then the report, with a log
│   └── Install-LabFilerTask.ps1  # run once on CAD4 (as admin) to create the 2am task
├── Logs/                   # only if the config can't be read: that night's log goes here instead, git-ignored
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
    ├── Holding/            # removed files wait here 7 days, in Holding/<YYYY-MM-DD>/
    ├── Journal/            # by month: 2026/11 Nov/2026-11-23_020004 run.csv + 2026-11-23_020004 nightly.log
    └── Reports/
        ├── Today's Report/      # only the newest PDF
        └── Archived Reports/    # every earlier PDF, by month: 2026/11 Nov/
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
- **Holding cleanup:** removed files go into a dated subfolder, `Holding/<YYYY-MM-DD>/`, named after the day they were removed. A date folder more than **7 days** old is deleted, and each delete is journaled. The clock goes by the folder date, not the file's own dates: a move keeps the old dates, so a 90-day-old ZIP would otherwise be deleted the very next night. Dated folders also stop the same ZIP name removed on different days from colliding. The 7 days is the `HoldingDays` config setting (changed from 14 to 7 on 2026-11-25).
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
   - every folder exists, including subfolder homes such as `Models/Stray FitFoot Files` (so a typo in that name stops the run instead of creating a new folder)
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
   - **Journal:** each run writes `Journal/<YYYY>/<MM Mon>/<RunId> run.csv` (see item 13 for the naming) with the columns RunId, Time, Action, Source, Destination, Result, Error. Each row is written straight after its action.
   - **Failures don't stop the run.** A failed action (e.g. a locked file) is recorded as `Failed` with the error, the run continues, and the script exits with code 1.
   - `Move-Item` without `-Force` never overwrites, which backs up the collision check.
   - Tested: dry run changes nothing; apply matches the answer key; a second apply does nothing; read-only `Scans` gives `Failed` rows and exit 1; `Delete` mode deletes the ZIPs.

9. Added Holding cleanup:
   - **Purge:** files in a `Holding/<YYYY-MM-DD>/` folder more than `HoldingDays` old are deleted. Each one is a `Purge` action, shown in the dry run and journaled like every other action. The folder is removed once it's empty, or left in place and reported if anything is still in it.
   - **Review:** anything else in `Holding` (loose files, folders not named as dates) goes on the review list.
   - **Tested:** the test data now includes Holding cases, including the exact-day edge (now 7 days).

10. Wrote `scripts/Undo-LabFilerRun.ps1`:
    - **What it reverses:** it finds the run's journal (a filer run or an earlier undo) and, last action first, moves each `Done` file from `Destination` back to `Source`.
    - **Dry run by default:** it changes nothing unless `-Apply` is passed.
    - **What it skips:** purges and `Delete`-mode removes (the file is gone), failed actions, files no longer at their destination, and anything whose original place is occupied. It never overwrites.
    - **Its own journal:** `Journal/<YYYY>/<MM Mon>/<UndoId> undo.csv`, with the same columns, so an undo can be undone too.
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
    - **Folders:** the report goes in `<ReportPath>/Today's Report/`, and whatever was there moves to `Archived Reports/<YYYY>/<MM Mon>/` first (the month comes from the date in the report's name), so `Today's Report` only ever holds the newest report. A report rebuilt with `-RunId` goes straight to that run's month in `Archived Reports`. The folder names are the `ReportTodayFolder` and `ReportArchiveFolder` settings. Ben reads the reports from this folder, instead of getting them by email.
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
12. Tested on Windows 11 (ARM, UTM VM) with **Windows PowerShell 5.1**. The repo was cloned to the VM's own `C:` drive, and only `PdfBrowserPath` was changed to Edge (not committed). The VM is on Pacific time, the same as CAD4 in Vancouver.
    - **Setup:** scripts need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` first, because Windows blocks `.ps1` files by default. The scheduled task doesn't: it runs with `-ExecutionPolicy Bypass`.
    - **Passed:**
      - **5.1 compatibility:** all scripts ran with no syntax errors.
      - **Dry run:** the output matched the Mac run and the answer key line for line.
      - **NTFS dates:** `118300 - Copied Back` (created 2 days ago, modified ~9 years ago) counts as 2 days old.
      - **Apply:** moves, archives into `09 existing`, removals to Holding and Holding purges all worked.
      - **Report:** Edge printed the PDF correctly, and the previous report rotated to `Archived Reports`.
      - **Undo:** 14 actions put back, and the 2 purges skipped as "cannot be restored". A dry run afterwards matched the first plan, minus the purges.
      - **Locked file:** a file held open with `[System.IO.File]::Open(path, 'Open', 'Read', 'None')` was marked `Failed` ("Applied 13 of 14", exit code 1). The rest of the run carried on, and the report showed the plain-English reason. There was **no duplicate** at the destination: a same-drive move on Windows is all or nothing, so the macOS quirk above doesn't happen here.
    - **Not tested yet:** an archive on a second drive (`D:`, as on CAD4), where a move is copy-then-delete. (The Task Scheduler setup was tested later: item 14.)
13. Made journal and report names readable, and filed them by month:
    - **Run ID:** the start time as `yyyy-MM-dd_HHmmss`, e.g. `2026-11-23_020004`. It reads as a date, sorts in time order, has no spaces (easy to type after `-RunId`), and keeps the seconds so two runs never share a journal. Undos get the same kind of ID.
    - **Journal names:** `<RunId> run.csv` for a filer run and `<RunId> undo.csv` for an undo. The kind goes at the end, so runs and undos sort together by time and an undo sits right after the run it reversed.
    - **Month folders:** journals go in `Journal/<YYYY>/<MM Mon>/` and older reports in `Archived Reports/<YYYY>/<MM Mon>/`, the same layout as Ben's archive. Month names are always English (`InvariantCulture`). The scripts create these folders themselves; the never-create rule is only for the patient-file archive.
    - **Shared helpers** in `LabFiler.Common.ps1`: `New-RunId`, `ConvertFrom-RunId`, `Get-MonthFolder`, `Get-JournalFile`, `Find-JournalFile`.
    - **Finding runs:** the undo script and `-RunId` work out the month folder from the run ID. The morning report searches all month folders for the newest `* run.csv`, so undo journals are still ignored. A run ID in the old format, or one with no journal, stops with a clear message and exit code 1.
    - **Tested on the Mac:** apply, report, second report (the first moved to `Archived Reports/2026/11 Nov/`), undo, undo of the undo (dry run), report rebuilt with `-RunId`, old-format and missing run IDs. **Re-tested on the Windows VM:** apply, both reports (rotation into `Archived Reports\2026\11 Nov\`) and undo all passed.
14. Wrote the nightly task scripts:
    - **`Start-LabFilerNightly.ps1`** is what the task runs: the filer with `-Apply`, then the report. The report runs even if the filer failed, so the failure shows up in it.
      - **Log:** a scheduled task has no window, so `Start-Transcript` saves everything printed to `<RunId> nightly.log` in the journal's month folder, next to that night's `<RunId> run.csv`. One folder holds everything about a night. The log matters on nights something went wrong, such as Edge failing to make the PDF.
      - **Fallback:** if the config can't be read or the journal folder doesn't exist, the log goes to `Logs/<YYYY>/<MM Mon>/` next to the scripts instead, and its first line says why. The log's name ends in `.log`, so the report and undo never mistake it for a journal.
      - **Result:** the log ends with `Filer:`, `Report:` and `Overall:`, each `SUCCESS` or `FAILED (exit code N)`. The script's exit code is still a number, because Windows requires one: 0 for SUCCESS, 1 for FAILED. Task Scheduler shows it as the task's "Last Run Result".
      - Each step's table goes through `Out-Host`, so it only reaches the screen and log, never the exit code. `$LASTEXITCODE` is reset to 0 before each step, because a script that finishes without `exit` leaves the old value.
    - **`Install-LabFilerTask.ps1`** is run once on CAD4 from an **administrator** PowerShell window. It creates `\Kintec\Lab Filer` in Task Scheduler, and running it again replaces the task. `-Remove` deletes it.
      - **When:** daily at `-At` (default `2:00 AM`).
      - **Rules:** run as soon as possible if CAD4 was off at 2am; wake from sleep; never two runs at once; stop after 3 hours; run on battery.
      - **Command:** `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<...>\Start-LabFilerNightly.ps1" -ConfigPath "<...>\config.json"`, with full paths. `Bypass` applies to this task only, so CAD4's execution policy doesn't need changing.
      - **Account:** `-User` defaults to whoever runs the installer. It asks for that account's password once, in the PowerShell window, and Windows stores it so the task runs while nobody is logged in. A wrong password is refused straight away.
      - **Not SYSTEM:** tested on the VM, Edge won't start under SYSTEM (exit code 1002, no messages), even with `--no-sandbox` and a fresh profile, so the report came out as HTML. SYSTEM also can't reach network folders. `-User SYSTEM` still works if a PDF isn't needed.
    - **Tested on the Mac:**
      - the nightly script ran both steps and wrote the log next to the journal (exit code 0);
      - a missing config made both steps fail and the script exit with 1, with the log in `Logs/` saying why;
      - the installer parses, and stops on a non-Windows machine.

    - **Tested on the Windows VM:** installed the task under the VM's own account, started it by hand: `LastTaskResult 0`, filer applied 16 of 16, the log next to the journal, and a real PDF in Today's Report. Still to check: a 2am run with nobody logged in.
    - **Report changes from this testing:** Edge's exit code goes in the log, Edge writes its own log (`--enable-logging=stderr`), each report uses a new browser profile folder (deleted afterwards), and the script waits up to 30 seconds for the PDF to appear.

```powershell
./scripts/Invoke-LabFiler.ps1                               # dry run
./scripts/Invoke-LabFiler.ps1 -Apply                        # make the changes
./scripts/Undo-LabFilerRun.ps1 -RunId 2026-11-02_220323       # dry run of an undo
./scripts/Undo-LabFilerRun.ps1 -RunId 2026-11-02_220323 -Apply
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
| Holding/<today − 8> | `423002 - Older Job.zip` | 8 | purge, folder removed |
| Holding/<today − 7> | `423003 - Edge Job.zip` | 7 | keep (exactly 7 days) |
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
2. **Config file** (`config.json`): root path, the four folders, archive and holding paths, the extension-to-folder table, removal extensions, age threshold (14 days), remove mode (`Holding` / `Delete`), holding retention (7 days).
3. **Startup validation:** stop if any configured folder doesn't exist.
4. **Classify only (read-only):** list each file in the four folders with the action it *would* get, and compare against the answer key above.
5. **Journal plus dry run**, then real moves.
6. **Holding cleanup:** delete `Holding/<YYYY-MM-DD>/` folders more than `HoldingDays` (now 7) days old, journaling each delete.
7. **Undo script** that reverses a run by run ID from the journal.
8. **Morning report:** done. The PDF goes into a `Today's Report` folder for Ben (see Done so far), instead of being emailed. Email can be added later if Kintec's mail system allows it.
9. ~~**Order-number parsing** as the third date in the age rule.~~ Skipped for now. Age stays the newest of created and modified date. Known risk: a current file that arrives with old dates on both (moved in, or copied back with dates kept) gets archived the next night. It can be brought back with the undo script.
10. ~~**Windows VM testing:** PowerShell 5.1, NTFS dates, file locks.~~ Done (see Done so far, item 12).
11. ~~**Task Scheduler setup script.**~~ Done and tested on the VM (see Done so far, item 14). It has to run as a real Windows account, not SYSTEM. Still to check: an overnight 2am run with nobody logged in.
12. **Cross-drive archive test:** add a second virtual disk as `D:` in the VM. Only needed if the four folders aren't on `D:` on CAD4.
13. **Install on CAD4:** follow [Installing on CAD4](#installing-on-cad4-step-by-step).

---

## Open questions (don't block the build)

- ~~What file types live in `NC Programs`?~~ Answered by Ben: `.pim` (in the `Lincoln` / `Obama` subfolders). Stray `.ort` files move to `Models`, and block-map `.pdf` files are deleted.
- ~~FreeFileSync direction on the workstations.~~ Answered by Ben: the jobs are all Two-way or Mirror (CAD4 → workstation), never Mirror plus Update.
  - Both pass CAD4's moves and deletions on, so archived files don't come back. That makes it safe to run against the real `Scans` and `Models`.
  - Edge case: if a Two-way job loses its `sync.ffs_db`, it could copy an archived file back. The next night that file collides with its copy in `Archive` and goes on the review list, so nothing is lost.
- ~~Which machine runs the filer, and when?~~ Answered by Ben: CAD4, at 2am. `Mill Jobs` / `NC Programs` will sync two ways between CAD5 and CAD4.
- **Where do the four folders live on CAD4?** The local path (behind the `Z:` share) is needed for `RootPath`. The config has one `RootPath` for all four folders, which only works if they all sit under one parent folder.
- Which Windows account runs the scheduled task? It must be a real account, not SYSTEM (Edge can't make the PDF under SYSTEM). Ideally a dedicated one, e.g. `CAD4\labfiler`, whose password doesn't change, because a changed password stops the task until the installer is run again. It needs write access to the four folders, the archive, Holding, the journal and the report folder.
- Morning report folder: where should `ReportPath` be, so Ben can open it from his own computer (e.g. a folder on the `Z:` share)? The account that runs the nightly task needs write access to it.
