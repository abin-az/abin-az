<#
.SYNOPSIS
    Fast, safe disk cleanup tool for Windows.
.DESCRIPTION
    Removes old files from common temporary/cache locations without doing expensive
    full-disk folder size scans. Designed for large drives where cleanup should finish
    quickly.

    Key behavior:
    - Requires administrator privileges.
    - Deletes files older than a retention threshold.
    - Expands wildcard target paths safely (for example user profile temp folders).
    - Skips missing paths and access errors safely.
    - Stops Windows Update service only when needed and restores it afterwards.
    - Optionally runs DISM component cleanup.
.PARAMETER AutoMode
    Run without interactive confirmation.
.PARAMETER Days
    Delete files older than this many days. Must be >= 1. Default: 15.
.PARAMETER SkipDism
    Skip DISM component cleanup.
.PARAMETER DriveLetter
    Drive letter for free-space reporting. Default: C.
.PARAMETER RemoveEmptyDirs
    Remove empty subdirectories after file cleanup.
    Disabled by default to avoid deleting app-expected folder structures.
.PARAMETER LogPath
    Optional path for an audit log containing deleted and skipped entries.
.PARAMETER MonitoringOutputPath
    Optional JSON output path for monitoring integrations (SCOM/LogicMonitor/etc.).
    Contains a small status payload including whether a reboot is required.
.EXAMPLE
    .\DiskCleanup.ps1 -AutoMode -Days 7
.EXAMPLE
    .\DiskCleanup.ps1 -AutoMode -Days 30 -SkipDism
.EXAMPLE
    .\DiskCleanup.ps1 -WhatIf
.EXAMPLE
    .\DiskCleanup.ps1 -AutoMode -MonitoringOutputPath "C:\Logs\DiskCleanup.status.json"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$AutoMode,

    [ValidateRange(1, 3650)]
    [int]$Days = 15,

    [switch]$SkipDism,

    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'C',

    [switch]$RemoveEmptyDirs,

    [string]$LogPath,

    [string]$MonitoringOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$script:LogEntries = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:LogEntries.Add("[$timestamp] $Message")
}

function Flush-Log {
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        return
    }

    try {
        $folder = Split-Path -Path $LogPath -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }
        $script:LogEntries | Out-File -LiteralPath $LogPath -Encoding UTF8 -Append
        Write-Host "Log written to: $LogPath" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "Could not write log to $LogPath : $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Write-MonitoringStatus {
    param(
        [bool]$RebootRequired,
        [Nullable[int]]$DismExitCode
    )

    if ([string]::IsNullOrWhiteSpace($MonitoringOutputPath)) {
        return
    }

    try {
        $folder = Split-Path -Path $MonitoringOutputPath -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }

        $payload = [pscustomobject]@{
            TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
            RebootRequired    = $RebootRequired
            DismExitCode      = $DismExitCode
            MaintenanceStatus = if ($RebootRequired) { 'MaintenanceRequired' } else { 'Healthy' }
        }

        $payload | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $MonitoringOutputPath -Encoding UTF8
        Write-Host "Monitoring status written to: $MonitoringOutputPath" -ForegroundColor DarkGray
        Write-Log "MONITOR payload written: $MonitoringOutputPath"
    }
    catch {
        Write-Host "Could not write monitoring status to $MonitoringOutputPath : $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Log "WARN monitoring payload write failed: $($_.Exception.Message)"
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeSpaceGb {
    param([string]$Letter)

    $drive = Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue
    if (-not $drive) {
        throw "Drive $Letter not found."
    }

    return [math]::Round($drive.Free / 1GB, 2)
}

function Resolve-CleanupPaths {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Expand wildcard paths (e.g. C:\Users\*\AppData\Local\Temp)
    if ($Path -match '[*?\[]') {
        $resolved = Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName -Unique
        return @($resolved)
    }

    if (Test-Path -LiteralPath $Path -PathType Container -ErrorAction SilentlyContinue) {
        return @($Path)
    }

    return @()
}

function Clean-Path {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [datetime]$CutoffDate,

        [switch]$DeleteEmptyDirs
    )

    $resolvedPaths = Resolve-CleanupPaths -Path $Path
    if ($resolvedPaths.Count -eq 0) {
        Write-Host "Skipping missing/unresolved path: $Path" -ForegroundColor DarkGray
        Write-Log "SKIP path unresolved: $Path"
        return [pscustomobject]@{ Path = $Path; DeletedFiles = 0; Errors = 0 }
    }

    $deleted = 0
    $errors = 0

    foreach ($resolvedPath in $resolvedPaths) {
        Write-Host "Cleaning: $resolvedPath (older than $Days days)" -ForegroundColor Yellow

        try {
            $files = Get-ChildItem -Path $resolvedPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $CutoffDate }

            foreach ($file in $files) {
                try {
                    if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete file')) {
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        $deleted++
                        Write-Log "DELETE file: $($file.FullName)"
                    }
                }
                catch {
                    $errors++
                    Write-Log "ERROR deleting file: $($file.FullName) | $($_.Exception.Message)"
                }
            }

            if ($DeleteEmptyDirs) {
                Get-ChildItem -Path $resolvedPath -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object {
                        try {
                            $childCount = (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                            if ($childCount -eq 0 -and $PSCmdlet.ShouldProcess($_.FullName, 'Delete empty directory')) {
                                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                                Write-Log "DELETE empty-dir: $($_.FullName)"
                            }
                        }
                        catch {
                            $errors++
                            Write-Log "ERROR deleting empty-dir: $($_.FullName) | $($_.Exception.Message)"
                        }
                    }
            }
        }
        catch {
            Write-Host "Error while scanning $resolvedPath : $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "ERROR scanning path: $resolvedPath | $($_.Exception.Message)"
            $errors++
        }
    }

    return [pscustomobject]@{ Path = $Path; DeletedFiles = $deleted; Errors = $errors }
}

Write-Host '==== FAST DISK CLEANUP TOOL ====' -ForegroundColor Cyan

if (-not (Test-IsAdministrator)) {
    Write-Host 'Run this script as Administrator.' -ForegroundColor Red
    exit 1
}

try {
    $freeBefore = Get-FreeSpaceGb -Letter $DriveLetter
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host "`nFree space before cleanup ($DriveLetter): $freeBefore GB" -ForegroundColor Yellow

$targets = @(
    'C:\Windows\Temp',
    'C:\Windows\SoftwareDistribution\Download',
    'C:\Windows\Minidump',
    'C:\Users\*\AppData\Local\Temp',
    'C:\Windows\Prefetch',
    'C:\inetpub\logs\LogFiles',
    'C:\Windows\Logs\CBS'
) | Select-Object -Unique

if (-not $AutoMode) {
    Write-Host "`nTargeted cleanup locations:" -ForegroundColor Cyan
    $targets | ForEach-Object { Write-Host "  $_" }

    $choice = Read-Host "`nProceed with cleanup? (Y/N)"
    if ($choice -notin @('Y', 'y')) {
        Write-Host 'Aborted.' -ForegroundColor Red
        exit 0
    }
}

$cutoff = (Get-Date).AddDays(-$Days)
Write-Host "`nStarting cleanup (cutoff: $($cutoff.ToString('yyyy-MM-dd HH:mm:ss'))) ..." -ForegroundColor Cyan

$wuauserv = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
$wasRunning = $false
$results = @()
$rebootRequired = $false
$dismExitCode = $null

try {
    if ($wuauserv -and $wuauserv.Status -eq 'Running') {
        Write-Host 'Stopping Windows Update service (wuauserv)...' -ForegroundColor Yellow
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction Stop
            $wasRunning = $true
        }
        catch {
            Write-Host 'Could not stop wuauserv; continuing cleanup.' -ForegroundColor DarkYellow
            Write-Log "WARN unable to stop wuauserv: $($_.Exception.Message)"
        }
    }

    foreach ($target in $targets) {
        $results += Clean-Path -Path $target -CutoffDate $cutoff -DeleteEmptyDirs:$RemoveEmptyDirs
    }

    Write-Host 'Clearing Recycle Bin...' -ForegroundColor Yellow
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Log 'CLEAR recycle-bin: success'
    }
    catch {
        Write-Host 'Recycle Bin cleanup skipped due to access/availability.' -ForegroundColor DarkYellow
        Write-Log "WARN recycle-bin cleanup skipped: $($_.Exception.Message)"
    }

    $dumpPath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name 'DumpFile' -ErrorAction SilentlyContinue).DumpFile
    if (-not [string]::IsNullOrWhiteSpace($dumpPath)) {
        Write-Host "Removing crash dump file if present: $dumpPath" -ForegroundColor Yellow
        try {
            Remove-Item -LiteralPath $dumpPath -Force -ErrorAction Stop
            Write-Log "DELETE dump-file: $dumpPath"
        }
        catch {
            Write-Log "WARN unable to delete dump-file $dumpPath: $($_.Exception.Message)"
        }
    }

    if (-not $SkipDism) {
        Write-Host 'Running DISM component cleanup (may take 5-15 minutes)...' -ForegroundColor Yellow
        try {
            $dism = Start-Process -FilePath 'dism.exe' -ArgumentList '/online /Cleanup-Image /StartComponentCleanup' -Wait -NoNewWindow -PassThru
            $knownSuccessCodes = @(0, 3010)
            $dismExitCode = $dism.ExitCode
            if ($dism.ExitCode -in $knownSuccessCodes) {
                if ($dism.ExitCode -eq 3010) {
                    $rebootRequired = $true
                    Write-Host 'DISM completed and indicates a reboot is recommended (3010).' -ForegroundColor DarkYellow
                    Write-Host 'Maintenance required: reboot to finalize component cleanup.' -ForegroundColor DarkYellow
                }
                Write-Log "DISM exit code: $($dism.ExitCode)"
            }
            else {
                Write-Host "DISM failed with exit code: $($dism.ExitCode)" -ForegroundColor Red
                Write-Log "ERROR DISM exit code: $($dism.ExitCode)"
            }
        }
        catch {
            Write-Host 'DISM cleanup encountered an error. Continuing...' -ForegroundColor Red
            Write-Log "ERROR DISM execution: $($_.Exception.Message)"
        }
    }
}
finally {
    if ($wasRunning) {
        Write-Host 'Starting Windows Update service (wuauserv)...' -ForegroundColor Yellow
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    }

    Flush-Log
    Write-MonitoringStatus -RebootRequired:$rebootRequired -DismExitCode $dismExitCode
}

Write-Host "`nRe-checking disk space..." -ForegroundColor Cyan
$freeAfter = Get-FreeSpaceGb -Letter $DriveLetter
$recovered = [math]::Round(($freeAfter - $freeBefore), 2)

Write-Host "Free space after cleanup ($DriveLetter): $freeAfter GB" -ForegroundColor Green
Write-Host "Space recovered: $recovered GB" -ForegroundColor Green

$totalDeleted = ($results | Measure-Object -Property DeletedFiles -Sum).Sum
$totalErrors = ($results | Measure-Object -Property Errors -Sum).Sum

Write-Host "Files deleted: $totalDeleted" -ForegroundColor Green
if ($totalErrors -gt 0) {
    Write-Host "Non-fatal errors encountered: $totalErrors" -ForegroundColor DarkYellow
}

Write-Host "`n==== CLEANUP COMPLETED ====" -ForegroundColor Cyan
