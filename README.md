# Fast Windows Disk Cleanup Script

A PowerShell script for **safe, high-impact cleanup** on Windows systems without slow full-disk recursive size scans.

> Script: `DiskCleanup.ps1`

## What this script does

- Verifies admin privileges.
- Reports free space before/after cleanup.
- Cleans old files (age-based) from common safe locations:
  - `C:\Windows\Temp`
  - `C:\Windows\SoftwareDistribution\Download`
  - `C:\Windows\Minidump`
  - `C:\Users\*\AppData\Local\Temp` (expanded safely per-profile)
  - `C:\Windows\Prefetch`
  - `C:\inetpub\logs\LogFiles`
  - `C:\Windows\Logs\CBS`
- Clears recycle bin.
- Removes configured crash dump file path (from registry) if present.
- Optionally runs DISM component cleanup with explicit exit-code handling.
- Automatically restores `wuauserv` service if it was running.
- Optionally writes an audit log via `-LogPath`.

## Improvements from previous version

- Fixed wildcard path handling so user temp folders are actually processed.
- Empty directory deletion is now **opt-in** via `-RemoveEmptyDirs` (safer defaults).
- Added resilient `wuauserv` stop behavior (warn and continue if stop fails).
- Added explicit DISM success handling for exit codes `0` and `3010`.
- Reads crash dump location from registry instead of hardcoding `C:\Windows\MEMORY.DMP`.
- Uses targeted error handling and keeps non-critical failures non-fatal.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Run in an elevated shell (**Run as Administrator**)

## Usage

```powershell
# Interactive mode (asks for confirmation)
.\DiskCleanup.ps1

# Fully automatic, delete files older than 7 days
.\DiskCleanup.ps1 -AutoMode -Days 7

# Automatic cleanup, skip DISM
.\DiskCleanup.ps1 -AutoMode -Days 15 -SkipDism

# Dry run using ShouldProcess support
.\DiskCleanup.ps1 -WhatIf

# Enable empty directory removal + write an audit log
.\DiskCleanup.ps1 -AutoMode -RemoveEmptyDirs -LogPath "C:\Logs\DiskCleanup.log"
```

## Suggested GitHub repo structure

```text
fast-windows-disk-cleanup/
├─ DiskCleanup.ps1
├─ README.md
├─ LICENSE
└─ .gitignore
```

## Suggested `.gitignore`

```gitignore
# PowerShell / logs
*.log
*.tmp

# VS Code
.vscode/

# OS
.DS_Store
Thumbs.db
```

## Safety notes

- The script does **not** run DISM `/ResetBase`.
- Access-denied or in-use files are skipped as non-fatal.
- Avoid `-RemoveEmptyDirs` unless you explicitly want directory pruning.
- For production systems, test in a staging/QA machine first.

## License

Use MIT for public sharing unless your organization requires another license.
