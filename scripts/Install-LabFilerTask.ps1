param(
    # When the task runs every night (Vancouver time on CAD4)
    [string]$At = '2:00 AM',
    [string]$TaskName = 'Lab Filer',
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config.json'),
    # SYSTEM needs no password and can use all of CAD4's own drives, but no network shares.
    # Give a real account (e.g. 'KINTEC\labadmin') if the reports or archive are on another PC;
    # the script then asks for its password.
    [string]$User = 'SYSTEM',
    # Removes the task instead of creating it
    [switch]$Remove
)

# Creates (or replaces) the nightly scheduled task that runs Start-LabFilerNightly.ps1.
# Run once on CAD4 from an administrator PowerShell window:
#   .\scripts\Install-LabFilerTask.ps1
# Running it again replaces the task, so it is safe to re-run after changing it.

# Tasks go in their own folder in Task Scheduler, so they're easy to find
$taskPath = '\Kintec\'

# --- Checks ---
# The ScheduledTasks commands only exist on Windows
if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host 'This script only works on Windows.'
    exit 1
}

# Creating a task that runs as SYSTEM, or while nobody is logged in, needs an administrator
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this from an administrator PowerShell window (right-click Windows PowerShell > Run as administrator).'
    exit 1
}

if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-Host "There is no task called '$TaskName' to remove."
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false
    Write-Host "Removed the task '$TaskName'."
    exit 0
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Host "Config file not found: $ConfigPath"
    exit 1
}
# The task needs full paths: it doesn't start in this folder
$ConfigPath   = (Resolve-Path -Path $ConfigPath).Path
$nightlyPath  = (Resolve-Path -Path (Join-Path $PSScriptRoot 'Start-LabFilerNightly.ps1')).Path

# [datetime] turns '2:00 AM' into a time; a typo stops here instead of making a broken task
$atTime = [datetime]::MinValue
if (-not [datetime]::TryParse($At, [ref]$atTime)) {
    Write-Host "'$At' is not a time. Use something like '2:00 AM'."
    exit 1
}

# --- What to run ---
# Windows PowerShell 5.1, with:
#   -NoProfile                 don't load anyone's personal PowerShell settings
#   -NonInteractive            never stop to ask a question (nobody is there at 2am)
#   -ExecutionPolicy Bypass    allow these scripts to run, for this task only
#   -File                      the script to run, then its own parameters
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
             "-File `"$nightlyPath`" -ConfigPath `"$ConfigPath`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments `
                                  -WorkingDirectory $PSScriptRoot

# --- When ---
$trigger = New-ScheduledTaskTrigger -Daily -At $atTime

# --- Rules ---
#   StartWhenAvailable       if CAD4 was off at 2am, run as soon as it's back on
#   WakeToRun                wake CAD4 from sleep to run
#   MultipleInstances        if last night's run is somehow still going, don't start a second one
#   ExecutionTimeLimit       stop a run that has hung for 3 hours
#   battery switches         run even on battery power (in case CAD4 is on a UPS)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
                                         -MultipleInstances IgnoreNew `
                                         -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
                                         -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$description = 'Tidies the lab CAD folders (Scans, Models, Mill Jobs, NC Programs) every night, ' +
               "then writes the morning report. Scripts: $PSScriptRoot"

# --- Who it runs as ---
# -Force replaces an existing task with the same name
if ($User -eq 'SYSTEM') {
    # ServiceAccount: runs whether or not anyone is logged in, and needs no password
    $runAs = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Action $action -Trigger $trigger `
                           -Settings $settings -Principal $runAs -Description $description -Force | Out-Null
}
else {
    # A real account must store its password so the task can run while nobody is logged in.
    # Read-Host asks in this window (Get-Credential opens a pop-up, which can hide behind it).
    # -AsSecureString shows * instead of the letters typed.
    $securePassword = Read-Host -AsSecureString "Windows password for $User (the nightly task runs as this account)"
    if ($securePassword.Length -eq 0) {
        Write-Host 'No password given, so the task was not created.'
        exit 1
    }
    # Register-ScheduledTask wants the password as plain text; a PSCredential converts it
    $credential = New-Object System.Management.Automation.PSCredential($User, $securePassword)
    try {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Action $action -Trigger $trigger `
                               -Settings $settings -Description $description -RunLevel Highest `
                               -User $credential.UserName `
                               -Password $credential.GetNetworkCredential().Password `
                               -Force -ErrorAction Stop | Out-Null
    }
    catch {
        # Windows checks the user name and password here, and refuses if either is wrong
        Write-Host "The task was not created: $($_.Exception.Message)"
        Write-Host "Check the user name (run 'whoami' to see yours) and the password, then try again."
        exit 1
    }
}

# --- Summary ---
Write-Host "Created the task '$TaskName' (Task Scheduler > Task Scheduler Library > Kintec)."
Write-Host "  Runs:    every day at $($atTime.ToString('h:mm tt'))"
Write-Host "  As:      $User"
Write-Host "  Command: powershell.exe $arguments"
Write-Host '  Logs:    in the journal folder, next to each night''s run.csv'
Write-Host "           (or $(Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Logs') if the config can't be read)"
Write-Host ''
Write-Host 'To test it now:'
Write-Host "  Start-ScheduledTask -TaskPath '$taskPath' -TaskName '$TaskName'"
Write-Host "  Get-ScheduledTaskInfo -TaskPath '$taskPath' -TaskName '$TaskName'   # LastTaskResult 0 = fine, 1 = needs a look"
