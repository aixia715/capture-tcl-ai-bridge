<#
.SYNOPSIS
    Installs the Capture Tcl AI bridge runtime files.

.DESCRIPTION
    Deploys the bridge, CLI, MCP server, Capture Tcl module, and the bundled
    Python runtime. With -EnableAutoStart, it also installs a snippet that
    starts the bridge when Capture launches. All deployed files are recorded in
    %LOCALAPPDATA%\capture-tcl-ai-bridge\install.json so captureAiBridge.tcl can
    find the broker and so uninstall.ps1 can prove which files this project owns.

    The installer never touches a file it cannot prove it owns. Every target is
    inspected before the first byte is copied, so a blocked target leaves the
    machine exactly as it was.

    Installing does not start Capture or the bridge.

.PARAMETER PythonTarget
    Directory receiving capture_tcl_bridge_server.py, capture_tcl_cli.py, and
    capture_mcp_server.py.

.PARAMETER CaptureTclTarget
    One or more existing capAutoLoad directories receiving captureAiBridge.tcl.
    When omitted, the installer detects every existing C:\Cadence\SPB_* Capture
    installation. Capture directories are never created.

.PARAMETER RuntimeSource
    Source directory containing the bundled Python runtime. Release ZIPs include
    it as runtime; this parameter is primarily useful for packaging tests.

.PARAMETER SkipRuntimeValidation
    Internal test switch. Do not use for normal installations.

.PARAMETER ForceOverwriteModified
    Overwrite an owned file whose content no longer matches the manifest, i.e.
    one that was edited in place after installation.

.PARAMETER EnableAutoStart
    Also install captureAiBridgeAutoStart.tcl, which starts the bridge when
    Capture launches instead of waiting for an explicit CaptureAiBridgeStart.

    This trades away a security property: without it the bridge exists only
    while an operator has deliberately opened it, and with it every Capture
    session opens the localhost port and writes a token file. The localhost
    binding and per-start token still stand, but they never protected against
    a process already running as the same Windows user - see docs/security.md.

.PARAMETER LogFile
    With -EnableAutoStart, the diagnostic log path the auto-start snippet
    configures. Without it the log stays off.
#>
param(
    [string]$PythonTarget = 'C:\tclpython',
    [string[]]$CaptureTclTarget = @(),
    [string]$RuntimeSource = (Join-Path $PSScriptRoot 'runtime'),
    [switch]$SkipRuntimeValidation,
    [switch]$ForceOverwriteModified,
    [switch]$EnableAutoStart,
    [string]$LogFile = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectName = 'capture-tcl-ai-bridge'
$SchemaVersion = 3
$SourceRoot = $PSScriptRoot

function Stop-Install {
    param([string]$Message)
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

function Get-CanonicalPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).ProviderPath $Path
    }
    return [IO.Path]::GetFullPath($Path)
}

function Get-CaptureTclTargets {
    param([string[]]$RequestedTargets)
    if ($RequestedTargets.Count -ne 0) { return @($RequestedTargets | ForEach-Object { Get-CanonicalPath $_ } | Select-Object -Unique) }
    $cadenceRoot = 'C:\Cadence'
    if (-not (Test-Path -LiteralPath $cadenceRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $cadenceRoot -Directory -Filter 'SPB_*' |
        ForEach-Object { Join-Path $_.FullName 'tools\capture\tclscripts\capAutoLoad' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        ForEach-Object { Get-CanonicalPath $_ } | Select-Object -Unique)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-JsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-BridgeManifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $data = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        return $null
    }
    $schema = Get-JsonProperty $data 'schemaVersion'
    if ($schema -ne 1 -and $schema -ne 2 -and $schema -ne $SchemaVersion) { return $null }
    if ((Get-JsonProperty $data 'project') -ne $ProjectName) { return $null }
    $pythonTarget = Get-JsonProperty $data 'pythonTarget'
    $captureTclTargets = if ($schema -eq 1) { @((Get-JsonProperty $data 'captureTclTarget')) } else { @(Get-JsonProperty $data 'captureTclTargets') }
    $runtimeTarget = if ($schema -eq 3) { Get-JsonProperty $data 'runtimeTarget' } else { $null }
    $pythonExecutable = if ($schema -eq 3) { Get-JsonProperty $data 'pythonExecutable' } else { $null }
    $files = Get-JsonProperty $data 'files'
    foreach ($value in @($pythonTarget) + $captureTclTargets + @($runtimeTarget, $pythonExecutable | Where-Object { $null -ne $_ })) {
        if ([string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value)) {
            return $null
        }
    }
    if ($null -eq $files) { return $null }
    return [pscustomobject]@{
        PythonTarget      = [IO.Path]::GetFullPath($pythonTarget)
        CaptureTclTargets = @($captureTclTargets | ForEach-Object { [IO.Path]::GetFullPath($_) })
        RuntimeTarget     = if ($null -ne $runtimeTarget) { [IO.Path]::GetFullPath($runtimeTarget) } else { $null }
        PythonExecutable   = if ($null -ne $pythonExecutable) { [IO.Path]::GetFullPath($pythonExecutable) } else { $null }
        Files             = @($files)
    }
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    $temporary = "$Path.$ProjectName.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $Text, $encoding)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

# --- Bundled runtime preflight --------------------------------------------

# --- Target preflight ------------------------------------------------------

$canonicalPythonTarget = Get-CanonicalPath $PythonTarget
$canonicalRuntimeSource = Get-CanonicalPath $RuntimeSource
$canonicalRuntimeTarget = Join-Path $canonicalPythonTarget 'runtime'
$canonicalPythonExecutable = Join-Path $canonicalRuntimeTarget 'python.exe'
$runtimePython = Join-Path $canonicalRuntimeSource 'python.exe'
if (-not (Test-Path -LiteralPath $canonicalRuntimeSource -PathType Container) -or
    -not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
    Stop-Install "bundled runtime is missing: $canonicalRuntimeSource"
}
if (-not $SkipRuntimeValidation) {
    try {
        & $runtimePython -c 'import fastapi, uvicorn' 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'dependency import failed' }
    } catch {
        Stop-Install "bundled runtime is incomplete; re-download the Release ZIP: $($_.Exception.Message)"
    }
}
$canonicalCaptureTclTargets = @(Get-CaptureTclTargets $CaptureTclTarget)
$manifestDirectory = Join-Path $env:LOCALAPPDATA $ProjectName
$manifestPath = Join-Path $manifestDirectory 'install.json'

$existing = Read-BridgeManifest $manifestPath
$owned = @{}
if ($null -ne $existing) {
    $existingTargets = @($existing.CaptureTclTargets | ForEach-Object { $_.ToLowerInvariant() })
    $requestedTargets = @($canonicalCaptureTclTargets | ForEach-Object { $_.ToLowerInvariant() })
    if ($existing.PythonTarget -ne $canonicalPythonTarget -or ($null -ne $existing.RuntimeTarget -and $existing.RuntimeTarget -ne $canonicalRuntimeTarget) -or @($existingTargets | Where-Object { $_ -notin $requestedTargets }).Count -ne 0) {
        Stop-Install ("$ProjectName is already installed with Python target '$($existing.PythonTarget)' and Capture Tcl target(s) '$($existing.CaptureTclTargets -join "', '")'. This invocation requests Python target '$canonicalPythonTarget' and Capture Tcl target(s) '$($canonicalCaptureTclTargets -join "', '")', so no files were copied or overwritten. Run uninstall.ps1 first, then install.ps1, to move the installation without orphaning the previous copies.")
    }
    foreach ($entry in $existing.Files) {
        $entryPath = Get-JsonProperty $entry 'path'
        $entryHash = Get-JsonProperty $entry 'sha256'
        if ([string]::IsNullOrWhiteSpace($entryPath) -or
            -not [IO.Path]::IsPathRooted($entryPath)) {
            continue
        }
        $owned[[IO.Path]::GetFullPath($entryPath).ToLowerInvariant()] =
            "$entryHash".ToLowerInvariant()
    }
}

$autoStartName = 'captureAiBridgeAutoStart.tcl'
$autoStartSource = $null
if ($EnableAutoStart) {
    # Built by concatenation rather than a here-string: the body is Tcl full
    # of $ and {}, and PowerShell would try to expand most of it.
    $nl = "`r`n"
    $autoStartBody = (@(
        '# Starts the Capture Tcl AI bridge when Capture launches.',
        '#',
        '# Installed by install.ps1 -EnableAutoStart. Delete this file, or re-run',
        '# uninstall.ps1, to go back to starting the bridge explicitly.',
        '#',
        '# capAutoLoad already sources captureAiBridge.tcl, which only defines',
        '# commands. This file is what turns that into a start, so the module',
        '# itself stays free of side effects and re-sourcing it never restarts a',
        '# bridge that is already running.',
        '',
        'if {[llength [info commands CaptureAiBridgeStart]] > 0} {'
    ) -join $nl) + $nl
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $logPath = (Get-CanonicalPath $LogFile) -replace '\\', '/'
        $autoStartBody += "    set ::CaptureAiBridgeLogFile {$logPath}" + $nl
    }
    $autoStartBody += (@(
        '    if {!$::CaptureAiBridgeActive && !$::CaptureAiBridgeConnecting} {',
        '        CaptureAiBridgeStart',
        '    }',
        '}'
    ) -join $nl) + $nl
    $autoStartSource = Join-Path ([IO.Path]::GetTempPath()) "capture-ai-autostart-$PID.tcl"
    [IO.File]::WriteAllText($autoStartSource, $autoStartBody,
        (New-Object System.Text.UTF8Encoding($false)))
}

$plan = @(
    [pscustomobject]@{
        Source = Join-Path $SourceRoot 'capture_tcl_bridge_server.py'
        Target = Join-Path $canonicalPythonTarget 'capture_tcl_bridge_server.py'
    }
    [pscustomobject]@{
        Source = Join-Path $SourceRoot 'capture_tcl_cli.py'
        Target = Join-Path $canonicalPythonTarget 'capture_tcl_cli.py'
    }
    [pscustomobject]@{
        Source = Join-Path $SourceRoot 'capture_mcp_server.py'
        Target = Join-Path $canonicalPythonTarget 'capture_mcp_server.py'
    }
)
$runtimeFiles = @(Get-ChildItem -LiteralPath $canonicalRuntimeSource -Recurse -File -Force)
foreach ($runtimeFile in $runtimeFiles) {
    $relative = $runtimeFile.FullName.Substring($canonicalRuntimeSource.Length).TrimStart('\')
    $plan += [pscustomobject]@{ Source = $runtimeFile.FullName; Target = (Join-Path $canonicalRuntimeTarget $relative) }
}
foreach ($target in $canonicalCaptureTclTargets) {
    $plan += [pscustomobject]@{ Source = Join-Path $SourceRoot 'captureAiBridge.tcl'; Target = Join-Path $target 'captureAiBridge.tcl' }
}
if ($EnableAutoStart) {
    foreach ($target in $canonicalCaptureTclTargets) { $plan += [pscustomobject]@{ Source = $autoStartSource; Target = (Join-Path $target $autoStartName) } }
}

$actions = @()
$blocked = @()
foreach ($item in $plan) {
    if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
        Stop-Install "runtime file is missing from the repository: $($item.Source)"
    }
    $sourceHash = Get-Sha256 $item.Source
    if (-not (Test-Path -LiteralPath $item.Target)) {
        $actions += [pscustomobject]@{ Item = $item; Copy = $true }
        continue
    }
    if (-not (Test-Path -LiteralPath $item.Target -PathType Leaf)) {
        $blocked += "$($item.Target) exists but is not a file."
        continue
    }
    $targetHash = Get-Sha256 $item.Target
    if ($targetHash -eq $sourceHash) {
        $actions += [pscustomobject]@{ Item = $item; Copy = $false }
        continue
    }
    $recorded = $owned[$item.Target.ToLowerInvariant()]
    if ($null -ne $recorded -and $recorded -eq $targetHash) {
        $actions += [pscustomobject]@{ Item = $item; Copy = $true }
        continue
    }
    if ($ForceOverwriteModified) {
        $actions += [pscustomobject]@{ Item = $item; Copy = $true }
        continue
    }
    if ($null -ne $recorded) {
        $blocked += ("$($item.Target) was modified after installation; " +
            're-run with -ForceOverwriteModified to replace it.')
    } else {
        $blocked += ("$($item.Target) already exists and is not owned by " +
            "$ProjectName; move it aside or re-run with -ForceOverwriteModified.")
    }
}

if ($blocked.Count -ne 0) {
    Stop-Install ("refusing to install; nothing was copied." + [Environment]::NewLine +
        ($blocked -join [Environment]::NewLine))
}

if ($canonicalCaptureTclTargets.Count -eq 0) {
    Write-Warning 'No existing Capture capAutoLoad directory was detected. Bridge files were installed, but Capture cannot load them until you re-run install.ps1 -CaptureTclTarget <existing capAutoLoad directory>.'
}

# --- Install ---------------------------------------------------------------

if (-not (Test-Path -LiteralPath $canonicalPythonTarget -PathType Container)) {
    New-Item -ItemType Directory -Path $canonicalPythonTarget -Force | Out-Null
}
foreach ($directory in $canonicalCaptureTclTargets) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        Stop-Install "Capture target directory does not exist; no Capture directories are created: $directory"
    }
}
if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) { New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null }

foreach ($action in $actions) {
    if (-not $action.Copy) { continue }
    $parent = Split-Path -Parent $action.Item.Target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = "$($action.Item.Target).$ProjectName.tmp"
    Copy-Item -LiteralPath $action.Item.Source -Destination $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $action.Item.Target -Force
}

$manifest = [ordered]@{
    schemaVersion    = $SchemaVersion
    project          = $ProjectName
    pythonTarget     = $canonicalPythonTarget
    runtimeTarget    = $canonicalRuntimeTarget
    pythonExecutable = $canonicalPythonExecutable
    captureTclTargets = @($canonicalCaptureTclTargets)
    files            = @($plan | ForEach-Object {
            [ordered]@{
                path   = $_.Target
                sha256 = Get-Sha256 $_.Target
            }
        })
}
Write-TextAtomic $manifestPath (ConvertTo-Json $manifest -Depth 5)

$captureTclFiles = @($plan | Where-Object { $_.Target -like '*captureAiBridge.tcl' } | ForEach-Object { $_.Target })

Write-Output "Installed ${ProjectName}:"
foreach ($item in $plan) { Write-Output "  $($item.Target)" }
Write-Output "  manifest: $manifestPath"
Write-Output ''
if ($EnableAutoStart -and $captureTclFiles.Count -ne 0) {
    Write-Output 'Auto-start is enabled: the bridge opens whenever Capture launches.'
    Write-Output 'Restart Capture, or start it once by hand, to pick this up:'
    foreach ($captureTclFile in $captureTclFiles) { Write-Output "  source $($captureTclFile -replace '\\', '/')" }
    Write-Output '  CaptureAiBridgeStart'
    Write-Output ''
    Write-Output 'To require an explicit start again, run uninstall.ps1 or delete:'
    foreach ($target in $canonicalCaptureTclTargets) { Write-Output "  $(Join-Path $target $autoStartName)" }
} elseif ($captureTclFiles.Count -ne 0) {
    Write-Output 'In the Capture Tcl console, load and start the bridge explicitly:'
    foreach ($captureTclFile in $captureTclFiles) { Write-Output "  source $($captureTclFile -replace '\\', '/')" }
    Write-Output '  CaptureAiBridgeStart'
    Write-Output '  CaptureAiBridgeStatus'
}
if ($null -ne $autoStartSource) { Remove-Item -LiteralPath $autoStartSource -Force }
