# backup.ps1
# Automates backups + optional scheduling via Task Scheduler

param(
    [switch]$SetupSchedule # Run as .\backup.ps1 -SetupSchedule to (re)register schedule
)

# --- Logging setup ---
$logDir = Join-Path $PSScriptRoot "logs"
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir ("backup-" + (Get-Date -Format "yyyyMMdd") + ".log")

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formatted = "[$timestamp] [$Level] $Message"
    Write-Host $formatted
    Add-Content -Path $logFile -Value $formatted
}

# --- Load configuration ---
$configPath = "backup-config.json"
if (!(Test-Path $configPath)) {
    Write-Log "Config file not found: $configPath. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above." "ERROR"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$sourceDir = $config.SourceDirectory
$backupDir = $config.BackupDirectory
$maxBackups = if ($config.MaxBackups) { [int]$config.MaxBackups } else { 10 }

# --- Backup function with live heartbeat ---
function Run-Backup {
    if (!(Test-Path $sourceDir)) {
        Write-Log "Source directory does not exist: $sourceDir. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above." "ERROR"
        exit 1
    }

    # Check if backup drive is available
    try {
        $item = Get-Item -Path $backupDir -ErrorAction Stop
        $backupDrive = $item.PSDrive
    } catch {
        $backupDrive = $null
    }

    if (-not $backupDrive) {
        Write-Log "Backup drive not found: $backupDir. Backup aborted. (Is the external HDD connected?)." "WARN"
        exit 1
    }

    # Create backup directory if missing
    if (!(Test-Path $backupDir)) {
        Write-Log "Creating backup folder: $backupDir"
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $backupDir ("Backup-$timestamp.zip")

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        Write-Log "Starting backup from '$sourceDir' to '$backupFile'. This may take a while..."

        # Start compression in a job
        $zipJob = Start-Job -ScriptBlock {
            param($source, $dest)
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $source,
                $dest,
                [System.IO.Compression.CompressionLevel]::Optimal,
                $false
            )
        } -ArgumentList $sourceDir, $backupFile

        # Heartbeat loop
        while (-not ($zipJob | Receive-Job -Keep -ErrorAction SilentlyContinue)) {
            Write-Log "Backup still running..."
            Start-Sleep -Seconds 30
        }

        # Wait and collect any final output/errors
        Receive-Job $zipJob -Wait | Out-Null
        Remove-Job $zipJob | Out-Null

        Write-Log "Backup completed successfully: $backupFile"

    } catch {
        Write-Log "Backup failed: $_. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above." "ERROR"
        exit 1
    }

    # --- Cleanup old backups ---
    $backups = Get-ChildItem -Path $backupDir -Filter "Backup-*.zip" | Sort-Object LastWriteTime -Descending
    if ($backups.Count -gt $maxBackups) {
        $toDelete = $backups | Select-Object -Skip $maxBackups
        foreach ($file in $toDelete) {
            try {
                Remove-Item $file.FullName -Force
                Write-Log "Deleted old backup: $($file.Name)"
            } catch {
                Write-Log "Failed to delete $($file.FullName): $_. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above." "WARN"
            }
        }
    }
}

# --- Scheduling functions ---
function Register-BackupTask {
    param($configPath)

    if (-not $config.Schedule.Enabled) {
        Write-Log "Scheduling is disabled in config."
        return
    }

    $taskName = "AutomatedBackupScript"

    # Safer script path detection
    if ($PSCommandPath) {
        $scriptPath = $PSCommandPath
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptPath = (Resolve-Path $MyInvocation.MyCommand.Path).Path
    } else {
        $scriptPath = (Get-Location).Path
        Write-Log "Could not detect script path reliably, using current directory: $scriptPath" "WARN"
    }

    $timeParts = $config.Schedule.Time -split "[:]"
    $hour = [int]$timeParts[0]
    $minute = [int]$timeParts[1]

    # Remove existing task if exists
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    switch ($config.Schedule.Frequency) {
        "Daily" {
            $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($hour).AddMinutes($minute).TimeOfDay)
        }
        "Weekly" {
            $trigger = New-ScheduledTaskTrigger -Weekly -At ([datetime]::Today.AddHours($hour).AddMinutes($minute).TimeOfDay)
        }
        "Hourly" {
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours($hour) `
                       -RepetitionInterval (New-TimeSpan -Hours 1) `
                       -RepetitionDuration (New-TimeSpan -Days 3650)  # 10 years
        }
        default {
            throw "Unsupported frequency: $($config.Schedule.Frequency). If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
        }
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -RunLevel Highest -Force

    Write-Log "Scheduled task '$taskName' created. Runs $($config.Schedule.Frequency) at $($config.Schedule.Time)."
}

function Ensure-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This operation requires Administrator privileges. Right-click PowerShell and select 'Run as administrator'." "ERROR"
        exit 1
    }
}

# --- Main ---
if ($SetupSchedule) {
    Ensure-Admin
    Register-BackupTask -configPath $configPath
} else {
    Run-Backup
}
