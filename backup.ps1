# backup.ps1
# Automates backups + optional scheduling via Task Scheduler

param(
  [switch]$SetupSchedule # Run as .\backup.ps1 -SetupSchedule to (re)register schedule
)

# Load configuration
$configPath = "backup-config.json"
if (!(Test-Path $configPath)) {
  Write-Error "Config file not found: $configPath. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
  exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$sourceDir = $config.SourceDirectory
$backupDir = $config.BackupDirectory
$maxBackups = if ($config.MaxBackups) { [int]$config.MaxBackups } else { 10 }

function Run-Backup {
  if (!(Test-Path $sourceDir)) {
    Write-Error "Source directory does not exist: $sourceDir. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
    exit 1
  }
 
  # Check if backup drive is available (compatible with PowerShell 5.1)
  try {
      $item = Get-Item -Path $backupDir -ErrorAction Stop
      $backupDrive = $item.PSDrive
  } catch {
      $backupDrive = $null
  }

  if (-not $backupDrive) {
      Write-Warning "Backup drive not found: $backupDir. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
      Write-Warning "Backup aborted. (Is the external HDD connected?). If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
      exit 1
  }

  # Create backup directory if only subfolder is missing
  if (!(Test-Path $backupDir)) {
    Write-Output "Creating backup folder: $backupDir"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  }

  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backupFile = Join-Path $backupDir ("Backup-$timestamp.zip")

  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
      $sourceDir,
      $backupFile,
      [System.IO.Compression.CompressionLevel]::Optimal,
      $false
    )
    Write-Output "Backup completed: $backupFile"
  }
  catch {
    Write-Error "Backup failed: $_. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
    exit 1
  }

  # Cleanup old backups
  $backups = Get-ChildItem -Path $backupDir -Filter "Backup-*.zip" | Sort-Object LastWriteTime -Descending
  if ($backups.Count -gt $maxBackups) {
    $toDelete = $backups | Select-Object -Skip $maxBackups
    foreach ($file in $toDelete) {
      try {
        Remove-Item $file.FullName -Force
        Write-Output "Deleted old backup: $($file.Name)"
      }
      catch {
        Write-Warning "Failed to delete $($file.FullName): $_. If help is required, call Sam Williamson on 04XX XXX XXX, citing the message above."
      }
    }
  }
}

function Register-BackupTask {
  param($configPath)

  if (-not $config.Schedule.Enabled) {
    Write-Output "Scheduling is disabled in config."
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
      Write-Warning "Could not detect script path reliably, using current directory: $scriptPath"
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

  Write-Output "Scheduled task '$taskName' created. Runs $($config.Schedule.Frequency) at $($config.Schedule.Time)."
}

function Ensure-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This operation requires Administrator privileges. Right-click PowerShell and select 'Run as administrator'."
        exit 1
    }
}

if ($SetupSchedule) {
  Ensure-Admin
  Register-BackupTask -configPath $configPath
}
else {
  Run-Backup
}
