# =====================================================================
# winpodx reverse-open — register the Linux app handlers in Windows.
#
# Reads `C:\Users\Public\winpodx\reverse-open\apps.json` (synced from
# the host) and creates per-app "Open with..." entries that surface each
# Linux app in Windows Explorer's right-click menu for the MIME
# extensions it advertises.
#
# Why per-app .cmd wrappers
# --------------------------
# Earlier revisions of this script registered each Linux app as a
# winpodx-<slug> ProgID whose `shell\open\command` invoked
# powershell.exe with the shim script. Windows' shell deduplicates
# the "Open with" menu by underlying EXE path -- every winpodx-<slug>
# ProgID's command line started with the same `powershell.exe`, so
# Explorer collapsed all N entries into a single "powershell" item.
#
# To get N distinct entries (one per Linux app, with its own name +
# icon), each app needs its OWN binary path from Windows' perspective.
# We achieve that with a per-slug `.cmd` wrapper under
# `C:\Users\Public\winpodx\reverse-open\bin\winpodx-<slug>.cmd` that
# just forwards %1 into the shared PowerShell shim. From Windows'
# POV these `.cmd` files are distinct executables, so each appears
# as a separate "Open with" entry with its FriendlyAppName + DefaultIcon.
#
# We register under `HKCU\Software\Classes\Applications\<exe>\`
# rather than as ProgIDs because that's the canonical Windows path
# for per-app handlers; the OpenWithList ext linkage (rather than
# OpenWithProgids) is the matching surface.
# =====================================================================

[CmdletBinding()]
param(
    [string]$AppsJson = 'C:\Users\Public\winpodx\reverse-open\apps.json',
    [string]$IconsDir = 'C:\Users\Public\winpodx\reverse-open\icons',
    [string]$BinDir = 'C:\Users\Public\winpodx\reverse-open\bin',
    [string]$ShimPath = 'C:\Users\Public\winpodx\reverse-open\shim\winpodx-reverse-open-shim.ps1',
    [string]$StartMenuDir = $(Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Linux Apps'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- helpers --------------------------------------------------------------

function Write-LogLine([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host "$ts [$Level] $Msg"
}

function Test-SlugValid([string]$Slug) {
    return $Slug -match '^[a-z0-9-]+$'
}

function Set-DefaultValue([string]$Key, [string]$Value) {
    # PowerShell's New-ItemProperty -Name '(default)' creates a value
    # named LITERALLY "(default)" -- it does NOT set the real unnamed
    # default value. The canonical way is Set-Item -Value, which the
    # registry provider routes to the default.
    if (-not (Test-Path -LiteralPath $Key)) {
        New-Item -Path $Key -Force | Out-Null
    }
    Set-Item -LiteralPath $Key -Value $Value
}

function Set-NamedValue([string]$Key, [string]$Name, [string]$Value) {
    if (-not (Test-Path -LiteralPath $Key)) {
        New-Item -Path $Key -Force | Out-Null
    }
    New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

# Curated MIME → extension table covering the most common types.
# Long-tail types fall through to a per-type-string fallback below
# (`Resolve-MimeExtensions`).
$script:DefaultMimeExt = @{
    'text/plain'       = @('.txt')
    'text/xml'         = @('.xml')
    'text/html'        = @('.html', '.htm')
    'text/css'         = @('.css')
    'text/markdown'    = @('.md', '.markdown')
    'application/json' = @('.json')
    'application/pdf'  = @('.pdf')
    'application/xml'  = @('.xml')
    'application/zip'  = @('.zip')
    'image/png'        = @('.png')
    'image/jpeg'       = @('.jpg', '.jpeg')
    'image/gif'        = @('.gif')
    'image/svg+xml'    = @('.svg')
    'image/webp'       = @('.webp')
    'image/bmp'        = @('.bmp')
    'image/tiff'       = @('.tif', '.tiff')
    'audio/mpeg'       = @('.mp3')
    'audio/ogg'        = @('.ogg')
    'audio/flac'       = @('.flac')
    'audio/wav'        = @('.wav')
    'video/mp4'        = @('.mp4')
    'video/webm'       = @('.webm')
    'video/x-matroska' = @('.mkv')
    'video/quicktime'  = @('.mov')
}

function Resolve-MimeExtensions([string]$Mime) {
    if ($script:DefaultMimeExt.ContainsKey($Mime)) {
        return $script:DefaultMimeExt[$Mime]
    }
    if ($Mime -match '^[a-z]+/(.+)$') {
        return @(".${matches[1]}".ToLowerInvariant())
    }
    return @()
}

# --- main -----------------------------------------------------------------

Write-LogLine 'INFO' "reading apps from $AppsJson"
if (-not (Test-Path -LiteralPath $AppsJson)) {
    Write-LogLine 'ERROR' 'apps.json missing — nothing to register'
    exit 1
}

$manifest = $null
try {
    $manifest = Get-Content -LiteralPath $AppsJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-LogLine 'ERROR' "apps.json parse failed: $($_.Exception.Message)"
    exit 2
}

if ($null -eq $manifest -or -not $manifest.PSObject.Properties['apps']) {
    Write-LogLine 'ERROR' 'apps.json has no apps array'
    exit 2
}

if (-not (Test-Path -LiteralPath $ShimPath)) {
    Write-LogLine 'ERROR' "shim missing at $ShimPath — refusing to register handlers that point at a nonexistent path"
    exit 3
}

if (-not (Test-Path -LiteralPath $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

$registered = 0
$skipped = 0
foreach ($app in $manifest.apps) {
    $slug = [string]$app.slug
    if (-not (Test-SlugValid $slug)) {
        Write-LogLine 'WARN' "skip invalid slug '$slug'"
        $skipped++
        continue
    }
    $name = [string]$app.name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $slug }

    # Honour the user's Linux-side default-handler choices from
    # ~/.config/mimeapps.list. Registering an app for every MIME it
    # *can* handle would flood the Windows "Open with" menu with
    # entries for every editor / image viewer / etc. -- noisy and
    # actively unhelpful. Instead, surface ONLY the apps the user has
    # explicitly set as their default on Linux, and only for the
    # extensions matching those MIME types.
    #
    # An app with empty `is_default_for` (the user hasn't picked it
    # as default for anything) is skipped entirely. The user can still
    # widen the registration scope later via the host-side allowlist
    # surface; the design doc covers that path in Phase 4.
    $mimes = @()
    if ($app.PSObject.Properties['is_default_for']) {
        foreach ($m in $app.is_default_for) { $mimes += [string]$m }
    }
    if ($mimes.Count -eq 0) {
        Write-LogLine 'INFO' "skip $slug — not the Linux default for any MIME type"
        $skipped++
        continue
    }
    $icoPath = Join-Path $IconsDir "$slug.ico"
    $cmdName = "winpodx-$slug.cmd"
    $cmdPath = Join-Path $BinDir $cmdName
    $friendly = "Open with $name (Linux)"

    # Write the per-slug .cmd wrapper. Each is a distinct binary
    # from Windows' POV so they appear as separate "Open with"
    # entries with their own names + icons.
    # %* preserves Windows' quoting of the file path; %1 is the
    # raw first arg which `Open with` substitutes with the file.
    $cmdContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ShimPath" -Slug "$slug" -File "%~1"
"@
    if ($DryRun) {
        Write-LogLine 'INFO' "[dry-run] would write $cmdPath + register $friendly for $($mimes -join ',')"
        $registered++
        continue
    }
    Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII -Force

    $appRoot = "HKCU:\Software\Classes\Applications\$cmdName"
    Set-NamedValue $appRoot 'FriendlyAppName' $friendly
    if (Test-Path -LiteralPath $icoPath) {
        Set-DefaultValue (Join-Path $appRoot 'DefaultIcon') "$icoPath,0"
    }
    Set-DefaultValue (Join-Path $appRoot 'shell\open\command') "`"$cmdPath`" `"%1`""

    # SupportedTypes lists every extension this app handles. The
    # value name is the extension; the value content is conventionally
    # empty. Windows uses this to decide whether to display the entry
    # in "Open with" for a given file type.
    $stKey = Join-Path $appRoot 'SupportedTypes'
    if (-not (Test-Path -LiteralPath $stKey)) {
        New-Item -Path $stKey -Force | Out-Null
    }

    $exts = New-Object System.Collections.Generic.HashSet[string]
    foreach ($mime in $mimes) {
        foreach ($ext in Resolve-MimeExtensions $mime) {
            if (-not $ext.StartsWith('.')) { continue }
            $extLower = $ext.ToLowerInvariant()
            if ($exts.Add($extLower)) {
                New-ItemProperty -Path $stKey -Name $extLower -Value '' -PropertyType String -Force | Out-Null
                # OpenWithList — alternative attach point that better
                # surfaces per-Application entries than OpenWithProgids.
                $extKey = "HKCU:\Software\Classes\$extLower\OpenWithList"
                if (-not (Test-Path -LiteralPath $extKey)) {
                    New-Item -Path $extKey -Force | Out-Null
                }
                New-ItemProperty -Path $extKey -Name $cmdName -Value '' -PropertyType String -Force | Out-Null
            }
        }
    }
    Write-LogLine 'INFO' "registered $slug (cmd=$cmdName) for $($exts.Count) extension(s)"
    $registered++
}

# --- Start Menu shortcuts for ALL discovered apps --------------------------
#
# Per-user Linux Apps menu folder. Carries every discovered app
# (regardless of whether the Linux user designated it as the default
# for any MIME type) so:
#   1. The apps launch directly from Start Menu (no file argument
#      needed -- the .cmd handles missing %1 gracefully).
#   2. The user can pick a non-default Linux app for one-shot file
#      open by going "Right-click → Open with → Choose another app
#      → Look for another app on this PC" and browsing to
#      %APPDATA%\Microsoft\Windows\Start Menu\Programs\Linux Apps
#      to select a .lnk.
#
# This is the spiritual answer to "default가 없는 앱들은 어떻게
# 할까?" -- the Linux defaults stream into the canonical Windows
# "Open with" menu; the rest land in a discoverable Start Menu
# folder.

$startMenuCount = 0
if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $StartMenuDir)) {
        New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell

    foreach ($app in $manifest.apps) {
        $slug = [string]$app.slug
        if (-not (Test-SlugValid $slug)) { continue }
        $name = [string]$app.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $slug }
        $icoPath = Join-Path $IconsDir "$slug.ico"
        $cmdPath = Join-Path $BinDir "winpodx-$slug.cmd"

        # If the per-app .cmd doesn't exist (because the app was
        # skipped at the registration pass for having no Linux
        # defaults), write it now so the shortcut has a target.
        if (-not (Test-Path -LiteralPath $cmdPath)) {
            $cmdContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ShimPath" -Slug "$slug" -File "%~1"
"@
            Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII -Force
        }

        # Sanitise the name for use as a filename — strip illegal
        # chars and trim. Display label stays in the .lnk's
        # Description (visible in tooltips).
        $safeName = ($name -replace '[\\/:*?"<>|]', '_').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $slug }
        $lnkPath = Join-Path $StartMenuDir "$safeName.lnk"

        try {
            $lnk = $shell.CreateShortcut($lnkPath)
            $lnk.TargetPath = $cmdPath
            $lnk.Description = "$name (Linux)"
            if (Test-Path -LiteralPath $icoPath) {
                $lnk.IconLocation = "$icoPath,0"
            }
            $lnk.Save()
            $startMenuCount++
        } catch {
            Write-LogLine 'WARN' "could not write shortcut for ${slug}: $($_.Exception.Message)"
        }
    }
}

Write-LogLine 'INFO' "done. registered=$registered skipped=$skipped start_menu=$startMenuCount"
exit 0
