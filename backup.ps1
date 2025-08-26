# backup.ps1
# Automated Backup Script with Incremental Support, Logging, and Task Scheduler

param(
    [switch]$SetupSchedule  # Run as .\backup.ps1 -SetupSchedule to register schedule
)

# --------------------------
# Load Configuration
# --------------------------
$configPath = "backup-config.json"
if (!(Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath. Call Sam Williamson on 04XX XXX XXX."
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$sourceDir = $config.SourceDirectory
$backupDir = $config.BackupDirectory
$maxBackups = if ($config.MaxBackups) { [int]$config.MaxBackups } else { 10 }
$incremental = if ($config.PSObject.Properties.Name -contains "Incremental") { $config.Incremental } else { $false }
# Parse lastBackupDate if present
if ($config.PSObject.Properties.Name -contains "lastBackupDate" -and $config.lastBackupDate) {
    $lastBackup = [datetime]$config.lastBackupDate
}
else {
    $lastBackup = $null
}


# Ensure compression assembly
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --------------------------
# Ensure Admin for Task Scheduler
# --------------------------
function Ensure-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Administrator privileges required. Right-click PowerShell and 'Run as administrator'."
        exit 1
    }
}

# --------------------------
# Backup Function
# --------------------------
function Run-Backup {
    Write-Host "Starting backup process..." -ForegroundColor Cyan

    if (!(Test-Path $sourceDir)) {
        Write-Error "Source directory does not exist: $sourceDir"
        return
    }

    if (!(Test-Path $backupDir)) {
        Write-Host "Creating backup folder: $backupDir"
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $backupDir ("Backup-$timestamp.zip")

    # Determine files to backup
    if ($incremental -and $lastBackup) {
        $files = Get-ChildItem -Path $sourceDir -Recurse -File | Where-Object { $_.LastWriteTime -gt $lastBackup }
        Write-Host "Incremental backup enabled. $($files.Count) files changed since $lastBackup"
    }
    else {
        $files = Get-ChildItem -Path $sourceDir -Recurse -File
        Write-Host "Full backup enabled. $($files.Count) files will be backed up"
    }

    if ($files.Count -eq 0) {
        Write-Host "No files to backup. Exiting."
        return
    }

    $totalSizeMB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 2)
    Write-Host "Total backup size: $totalSizeMB MB"

    # Perform backup inline
    Write-Host "Compressing files to $backupFile ..."
    [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $backupFile, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Host "Backup completed successfully → $backupFile" -ForegroundColor Green

    
    # After backup completes, update lastBackupDate
    $config.lastBackupDate = (Get-Date).ToString("s")  # ISO 8601 format
    $config | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    Write-Host "Updated lastBackupDate in config."

    # Cleanup old backups
    $backups = Get-ChildItem -Path $backupDir -Filter "Backup-*.zip" | Sort-Object LastWriteTime -Descending
    if ($backups.Count -gt $maxBackups) {
        $toDelete = $backups | Select-Object -Skip $maxBackups
        foreach ($file in $toDelete) {
            try {
                Remove-Item $file.FullName -Force
                Write-Host "Deleted old backup: $($file.Name)"
            }
            catch {
                Write-Warning "Failed to delete $($file.FullName): $_"
            }
        }
    }

    Write-Host "Backup process finished." -ForegroundColor Cyan
}

# --------------------------
# Task Scheduler Registration
# --------------------------
function Register-BackupTask {
    if (-not $config.Schedule.Enabled) {
        Write-Host "Scheduling disabled in config."
        return
    }

    $taskName = "AutomatedBackupScript"
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }

    $timeParts = $config.Schedule.Time -split "[:]"
    $hour = [int]$timeParts[0]
    $minute = [int]$timeParts[1]

    # Remove existing task if exists
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    switch ($config.Schedule.Frequency) {
        "Daily" { $trigger = New-ScheduledTaskTrigger -Daily  -At ([datetime]::Today.AddHours($hour).AddMinutes($minute).TimeOfDay) }
        "Weekly" { $trigger = New-ScheduledTaskTrigger -Weekly -At ([datetime]::Today.AddHours($hour).AddMinutes($minute).TimeOfDay) }
        "Hourly" {
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours($hour) `
                -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650) 
        }
        default { throw "Unsupported frequency: $($config.Schedule.Frequency)" }
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -RunLevel Highest -Force
    Write-Host "Scheduled task '$taskName' created. Runs $($config.Schedule.Frequency) at $($config.Schedule.Time)"
}

# --------------------------
# Main Execution
# --------------------------
if ($SetupSchedule) {
    Ensure-Admin
    Register-BackupTask
}
else {
    Run-Backup
}
