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
  - `C:\Users\*\AppData\Local\Temp`
  - `C:\Windows\Prefetch`
  - `C:\inetpub\logs\LogFiles`
  - `C:\Windows\Logs\CBS`
- Clears recycle bin.
- Removes `C:\Windows\MEMORY.DMP` (if present).
- Optionally runs DISM component cleanup.
- Automatically restores `wuauserv` service if it was running.

## Why this version is improved

Compared to the original pasted script, this rewrite adds:

- Strict mode and safer error handling.
- Parameter validation (`Days`, `DriveLetter`).
- `-SkipDism` switch for faster runs.
- Better service handling with `try/finally`.
- Cleanup summary (deleted file count + non-fatal errors).
- Duplicate-block issue removed (the original content appeared duplicated).

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

# Report/free-space on another drive letter
.\DiskCleanup.ps1 -AutoMode -DriveLetter D
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

- This script does **not** run `/ResetBase` with DISM.
- Access-denied or in-use files are skipped as non-fatal.
- For production systems, test in a staging/QA machine first.

## License

Use MIT for public sharing unless your organization requires another license.
