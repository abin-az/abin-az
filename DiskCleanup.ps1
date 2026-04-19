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
.EXAMPLE
    .\DiskCleanup.ps1 -AutoMode -Days 7
.EXAMPLE
    .\DiskCleanup.ps1 -AutoMode -Days 30 -SkipDism
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$AutoMode,

    [ValidateRange(1, 3650)]
    [int]$Days = 15,

    [switch]$SkipDism,

    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'C'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeSpaceGb {
    param([string]$Letter)
    $drive = Get-PSDrive -Name $Letter -ErrorAction Stop
    return [math]::Round($drive.Free / 1GB, 2)
}

function Clean-Path {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [datetime]$CutoffDate
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction SilentlyContinue)) {
        Write-Host "Skipping missing path: $Path" -ForegroundColor DarkGray
        return [pscustomobject]@{ Path = $Path; DeletedFiles = 0; Errors = 0 }
    }

    Write-Host "Cleaning: $Path (older than $Days days)" -ForegroundColor Yellow

    $deleted = 0
    $errors = 0

    try {
        $files = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $CutoffDate }

        foreach ($file in $files) {
            try {
                if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete file')) {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $deleted++
                }
            }
            catch {
                $errors++
            }
        }

        # Remove empty subdirectories to reduce clutter
        Get-ChildItem -Path $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                try {
                    $childCount = (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                    if ($childCount -eq 0 -and $PSCmdlet.ShouldProcess($_.FullName, 'Delete empty directory')) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    }
                }
                catch {
                    $errors++
                }
            }
    }
    catch {
        Write-Host "Error while scanning $Path : $($_.Exception.Message)" -ForegroundColor Red
        $errors++
    }

    return [pscustomobject]@{ Path = $Path; DeletedFiles = $deleted; Errors = $errors }
}

Write-Host "==== FAST DISK CLEANUP TOOL ====" -ForegroundColor Cyan

if (-not (Test-IsAdministrator)) {
    Write-Host 'Run this script as Administrator.' -ForegroundColor Red
    exit 1
}

$freeBefore = Get-FreeSpaceGb -Letter $DriveLetter
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

try {
    if ($wuauserv -and $wuauserv.Status -eq 'Running') {
        Write-Host 'Stopping Windows Update service (wuauserv)...' -ForegroundColor Yellow
        Stop-Service -Name wuauserv -Force -ErrorAction Stop
        $wasRunning = $true
    }

    foreach ($target in $targets) {
        $results += Clean-Path -Path $target -CutoffDate $cutoff
    }

    Write-Host 'Clearing Recycle Bin...' -ForegroundColor Yellow
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
    }
    catch {
        Write-Host 'Recycle Bin cleanup skipped due to access/availability.' -ForegroundColor DarkYellow
    }

    Write-Host 'Removing MEMORY.DMP if present...' -ForegroundColor Yellow
    try {
        Remove-Item -LiteralPath 'C:\Windows\MEMORY.DMP' -Force -ErrorAction Stop
    }
    catch {
        # No-op if missing or locked
    }

    if (-not $SkipDism) {
        Write-Host 'Running DISM component cleanup (may take 5-15 minutes)...' -ForegroundColor Yellow
        try {
            $dism = Start-Process -FilePath 'dism.exe' -ArgumentList '/online /Cleanup-Image /StartComponentCleanup' -Wait -NoNewWindow -PassThru
            if ($dism.ExitCode -ne 0) {
                Write-Host "DISM completed with warnings (exit code: $($dism.ExitCode))." -ForegroundColor DarkYellow
            }
        }
        catch {
            Write-Host 'DISM cleanup encountered an error. Continuing...' -ForegroundColor Red
        }
    }
}
finally {
    if ($wasRunning) {
        Write-Host 'Starting Windows Update service (wuauserv)...' -ForegroundColor Yellow
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    }
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
