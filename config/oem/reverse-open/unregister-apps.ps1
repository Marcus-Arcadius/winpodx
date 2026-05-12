# =====================================================================
# winpodx reverse-open — remove the Linux app handlers from Windows.
#
# Mirrors register-apps.ps1's per-app .cmd wrapper scheme:
#   * Strip winpodx-<slug>.cmd entries from every <ext>\OpenWithList
#     subkey under HKCU\Software\Classes
#   * Remove HKCU\Software\Classes\Applications\winpodx-<slug>.cmd
#   * Delete the matching .cmd files from $BinDir
#
# Legacy scrub: earlier revisions of register-apps.ps1 registered
# winpodx-<slug> ProgIDs under HKCU\Software\Classes\winpodx-<slug>
# and attached via OpenWithProgids. This script also walks + removes
# those so users who hit the pre-fix revision don't have orphans.
#
# Idempotent: missing keys / missing values / missing files are
# silently OK.
# =====================================================================

[CmdletBinding()]
param(
    [string]$BinDir = 'C:\Users\Public\winpodx\reverse-open\bin',
    [string]$StartMenuDir = $(Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Linux Apps'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-LogLine([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "$ts [$Level] $Msg"
}

$classesRoot = 'HKCU:\Software\Classes'
if (-not (Test-Path -LiteralPath $classesRoot)) {
    Write-LogLine 'INFO' 'no HKCU classes root — nothing to clean'
    exit 0
}

# --- legacy ProgIDs (pre-fix revision) ---
$legacyProgIds = @()
try {
    $legacyProgIds = Get-ChildItem -LiteralPath $classesRoot -ErrorAction Stop |
        Where-Object { $_.PSChildName -like 'winpodx-*' -and $_.PSChildName -notlike '*.cmd' } |
        Select-Object -ExpandProperty PSChildName
} catch {
    Write-LogLine 'WARN' "enumerate legacy ProgIDs failed: $($_.Exception.Message)"
}
$removedLegacy = 0
foreach ($progId in $legacyProgIds) {
    $progRoot = Join-Path $classesRoot $progId
    if ($DryRun) {
        Write-LogLine 'INFO' "[dry-run] would remove legacy ProgID $progRoot"
        $removedLegacy++
        continue
    }
    try {
        Remove-Item -LiteralPath $progRoot -Recurse -Force -ErrorAction Stop
        Write-LogLine 'INFO' "removed legacy ProgID $progRoot"
        $removedLegacy++
    } catch {
        Write-LogLine 'WARN' "could not remove ${progRoot}: $($_.Exception.Message)"
    }
}

# --- per-app .cmd wrappers under Applications\ ---
$apps = @()
$appsRoot = Join-Path $classesRoot 'Applications'
if (Test-Path -LiteralPath $appsRoot) {
    try {
        $apps = Get-ChildItem -LiteralPath $appsRoot -ErrorAction Stop |
            Where-Object { $_.PSChildName -like 'winpodx-*.cmd' } |
            Select-Object -ExpandProperty PSChildName
    } catch {
        Write-LogLine 'WARN' "enumerate Applications failed: $($_.Exception.Message)"
    }
}
$removedApps = 0
foreach ($cmdName in $apps) {
    $appKey = Join-Path $appsRoot $cmdName
    if ($DryRun) {
        Write-LogLine 'INFO' "[dry-run] would remove $appKey"
        $removedApps++
        continue
    }
    try {
        Remove-Item -LiteralPath $appKey -Recurse -Force -ErrorAction Stop
        Write-LogLine 'INFO' "removed $appKey"
        $removedApps++
    } catch {
        Write-LogLine 'WARN' "could not remove ${appKey}: $($_.Exception.Message)"
    }
}

# --- per-ext OpenWithList + OpenWithProgids ref strip ---
$removedExtRefs = 0
try {
    $extKeys = Get-ChildItem -LiteralPath $classesRoot -ErrorAction Stop |
        Where-Object { $_.PSChildName -like '.*' }
} catch {
    $extKeys = @()
}
foreach ($ext in $extKeys) {
    foreach ($subName in @('OpenWithList', 'OpenWithProgids')) {
        $subKey = Join-Path $ext.PSPath $subName
        if (-not (Test-Path -LiteralPath $subKey)) { continue }
        $props = $null
        try {
            $props = Get-ItemProperty -LiteralPath $subKey -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -like 'winpodx-*') {
                if ($DryRun) {
                    Write-LogLine 'INFO' "[dry-run] would strip $($prop.Name) from $subKey"
                    $removedExtRefs++
                    continue
                }
                try {
                    Remove-ItemProperty -LiteralPath $subKey -Name $prop.Name -Force -ErrorAction Stop
                    $removedExtRefs++
                } catch {
                    Write-LogLine 'WARN' "could not strip $($prop.Name) from ${subKey}: $($_.Exception.Message)"
                }
            }
        }
    }
}

# --- delete the per-slug .cmd files ---
$removedFiles = 0
if (Test-Path -LiteralPath $BinDir) {
    try {
        $files = Get-ChildItem -LiteralPath $BinDir -Filter 'winpodx-*.cmd' -ErrorAction Stop
    } catch {
        $files = @()
    }
    foreach ($f in $files) {
        if ($DryRun) {
            Write-LogLine 'INFO' "[dry-run] would delete $($f.FullName)"
            $removedFiles++
            continue
        }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $removedFiles++
        } catch {
            Write-LogLine 'WARN' "could not delete $($f.FullName): $($_.Exception.Message)"
        }
    }
}

# --- Start Menu shortcuts directory ---
$removedShortcuts = 0
if (Test-Path -LiteralPath $StartMenuDir) {
    if ($DryRun) {
        Write-LogLine 'INFO' "[dry-run] would delete shortcut dir $StartMenuDir"
        $removedShortcuts = 1
    } else {
        try {
            Remove-Item -LiteralPath $StartMenuDir -Recurse -Force -ErrorAction Stop
            $removedShortcuts = 1
        } catch {
            Write-LogLine 'WARN' "could not remove ${StartMenuDir}: $($_.Exception.Message)"
        }
    }
}

Write-LogLine 'INFO' "done. legacy_progids=$removedLegacy apps=$removedApps ext_refs=$removedExtRefs files=$removedFiles start_menu=$removedShortcuts"
exit 0
