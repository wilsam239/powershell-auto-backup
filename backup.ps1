# backup.ps1
# Automated Backup Script with Incremental Support (copy files instead of zip), Logging, and Scheduler

param(
    [switch]$SetupSchedule
)

# --------------------------
# Load configuration
# --------------------------
$configPath = "backup-config.json"
if (!(Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$sourceDir = (Resolve-Path $config.SourceDirectory).ProviderPath
$backupDir = (Resolve-Path $config.BackupDirectory).ProviderPath
$maxBackups = if ($config.MaxBackups) { [int]$config.MaxBackups } else { 10 }
$incremental = if ($config.PSObject.Properties.Name -contains "Incremental") { $config.Incremental } else { $false }
$lastBackup = if ($config.PSObject.Properties.Name -contains "lastBackupDate" -and $config.lastBackupDate) {
    [datetime]$config.lastBackupDate
}
else { $null }

# --------------------------
# Backup function
# --------------------------
function Run-Backup {

    Write-Host "Starting backup..." -ForegroundColor Cyan

    if (!(Test-Path $sourceDir)) {
        Write-Error "Source directory does not exist: $sourceDir"
        return
    }

    if (!(Test-Path $backupDir)) {
        Write-Host "Creating backup directory: $backupDir"
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    
    if ($incremental -and $lastBackup) {
        # Incremental: copy files changed since last backup
        $filesToCopy = Get-ChildItem -Path $sourceDir -Recurse -File | Where-Object { $_.LastWriteTime -gt $lastBackup }
        $totalFiles = $filesToCopy.Count

        if ($totalFiles -eq 0) {
            Write-Host "No files changed since last backup. Exiting incremental backup."
            return
        }

        Write-Host "Incremental backup: $totalFiles files to copy."

        $counter = 0
        foreach ($file in $filesToCopy) {
            $relativePath = $file.FullName.Substring($sourceDir.Length).TrimStart('\')
            $destPath = Join-Path $backupDir $relativePath
            $destDir = Split-Path $destPath
            if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item -Path $file.FullName -Destination $destPath -Force

            # Heartbeat log
            $counter++
            Write-Host "[$counter/$totalFiles] Copied: $relativePath"
        }

        Write-Host "Incremental backup complete." -ForegroundColor Green
    }

    else {
        # Full backup: zip entire directory
        $backupFile = Join-Path $backupDir ("Backup-$timestamp.zip")
        Write-Host "Full backup (zip) to $backupFile ..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($sourceDir, $backupFile, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        Write-Host "Full backup complete: $backupFile"
    }

    # Update lastBackupDate
    $config.lastBackupDate = (Get-Date).ToString("s")
    $config | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    Write-Host "Updated lastBackupDate in config."

    # Cleanup old backups
    if (-not $incremental) {
        $backups = Get-ChildItem -Path $backupDir -Filter "Backup-*.zip" | Sort-Object LastWriteTime -Descending
        if ($backups.Count -gt $maxBackups) {
            $toDelete = $backups | Select-Object -Skip $maxBackups
            foreach ($file in $toDelete) {
                try { Remove-Item $file.FullName -Force; Write-Host "Deleted old backup: $($file.Name)" }
                catch { Write-Warning "Failed to delete $($file.FullName): $_" }
            }
        }
    }

    Write-Host "Backup process finished." -ForegroundColor Cyan
}

# --------------------------
# Task Scheduler function
# --------------------------
function Register-BackupTask {
    # existing scheduler registration logic...
}

# --------------------------
# Main
# --------------------------
if ($SetupSchedule) {
    # Ensure admin + register task
}
else {
    Run-Backup
}
