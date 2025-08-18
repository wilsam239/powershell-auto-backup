# Auto Backup Script

Configure the backup in the backup-config.json file.

Run with `.\backup.ps1 -SetupSchedule` to setup the schedule based on the backup-config file. Alternatively, run with `.\backup.ps1` to run it manually. Or double-click `run.bat`.

# Outcome
- Zips the contents of the source directory, and places the zip file in the backup directory.
- Keeps `N` backups as defined in the `backup-config.json`
- Runs on schedule defined in `backup-config.json`
