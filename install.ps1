<#
.SYNOPSIS
    Installs the Capture Tcl AI bridge runtime files.

.DESCRIPTION
    Copies the three runtime files - the broker, the CLI and the Capture Tcl
    module - plus, with -EnableAutoStart, a fourth that starts the bridge when
    Capture launches. All of them are recorded in
    %LOCALAPPDATA%\capture-tcl-ai-bridge\install.json so captureAiBridge.tcl can
    find the broker and so uninstall.ps1 can prove which files this project owns.

    The installer never touches a file it cannot prove it owns. Every target is
    inspected before the first byte is copied, so a blocked target leaves the
    machine exactly as it was.

    Installing does not start Capture or the bridge.

.PARAMETER PythonTarget
    Directory receiving capture_tcl_bridge_server.py and capture_tcl_cli.py.

.PARAMETER CaptureTclTarget
    Directory receiving captureAiBridge.tcl.

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
    [string]$CaptureTclTarget = 'C:\cadence\SPB_17.4\tools\capture\tclscripts\capAutoLoad',
    [switch]$ForceOverwriteModified,
    [switch]$EnableAutoStart,
    [string]$LogFile = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectName = 'capture-tcl-ai-bridge'
$SchemaVersion = 1
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
    if ((Get-JsonProperty $data 'schemaVersion') -ne $SchemaVersion) { return $null }
    if ((Get-JsonProperty $data 'project') -ne $ProjectName) { return $null }
    $pythonTarget = Get-JsonProperty $data 'pythonTarget'
    $captureTclTarget = Get-JsonProperty $data 'captureTclTarget'
    $files = Get-JsonProperty $data 'files'
    foreach ($value in @($pythonTarget, $captureTclTarget)) {
        if ([string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value)) {
            return $null
        }
    }
    if ($null -eq $files) { return $null }
    return [pscustomobject]@{
        PythonTarget     = [IO.Path]::GetFullPath($pythonTarget)
        CaptureTclTarget = [IO.Path]::GetFullPath($captureTclTarget)
        Files            = @($files)
    }
}

function Invoke-Python {
    param([string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& python @Arguments 2>&1 | Out-String)
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "$_" }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    $temporary = "$Path.$ProjectName.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $Text, $encoding)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

# --- Interpreter preflight -------------------------------------------------

$version = Invoke-Python @('--version')
if ($version.ExitCode -ne 0) {
    Stop-Install "could not run 'python' from PATH: $($version.Output)"
}
if ($version.Output -notmatch 'Python\s+(\d+)\.(\d+)') {
    Stop-Install "could not read a version from 'python --version': $($version.Output)"
}
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 12)) {
    Stop-Install ("$ProjectName requires Python 3.12 or newer, but 'python' on " +
        "PATH reports $($version.Output).")
}

$dependencies = Invoke-Python @('-c', 'import fastapi, uvicorn')
if ($dependencies.ExitCode -ne 0) {
    Stop-Install ("$ProjectName requires the fastapi and uvicorn packages. " +
        "Install them with 'python -m pip install -r requirements.txt'.")
}

# --- Target preflight ------------------------------------------------------

$canonicalPythonTarget = Get-CanonicalPath $PythonTarget
$canonicalCaptureTclTarget = Get-CanonicalPath $CaptureTclTarget
$manifestDirectory = Join-Path $env:LOCALAPPDATA $ProjectName
$manifestPath = Join-Path $manifestDirectory 'install.json'

$existing = Read-BridgeManifest $manifestPath
$owned = @{}
if ($null -ne $existing) {
    if ($existing.PythonTarget -ne $canonicalPythonTarget -or
        $existing.CaptureTclTarget -ne $canonicalCaptureTclTarget) {
        Stop-Install (
            "$ProjectName is already installed into '$($existing.PythonTarget)' and " +
            "'$($existing.CaptureTclTarget)'. Run uninstall.ps1 before installing " +
            'into different directories, so the previous copies are not orphaned.')
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
$autoStartTarget = Join-Path $canonicalCaptureTclTarget $autoStartName
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
        Source = Join-Path $SourceRoot 'captureAiBridge.tcl'
        Target = Join-Path $canonicalCaptureTclTarget 'captureAiBridge.tcl'
    }
)
if ($EnableAutoStart) {
    $plan += [pscustomobject]@{ Source = $autoStartSource; Target = $autoStartTarget }
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

# --- Install ---------------------------------------------------------------

foreach ($directory in @($canonicalPythonTarget, $canonicalCaptureTclTarget, $manifestDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

foreach ($action in $actions) {
    if (-not $action.Copy) { continue }
    $temporary = "$($action.Item.Target).$ProjectName.tmp"
    Copy-Item -LiteralPath $action.Item.Source -Destination $temporary -Force
    Move-Item -LiteralPath $temporary -Destination $action.Item.Target -Force
}

$manifest = [ordered]@{
    schemaVersion    = $SchemaVersion
    project          = $ProjectName
    pythonTarget     = $canonicalPythonTarget
    captureTclTarget = $canonicalCaptureTclTarget
    files            = @($plan | ForEach-Object {
            [ordered]@{
                path   = $_.Target
                sha256 = Get-Sha256 $_.Target
            }
        })
}
Write-TextAtomic $manifestPath (ConvertTo-Json $manifest -Depth 5)

$captureTclFile = ($plan | Where-Object { $_.Target -like '*captureAiBridge.tcl' }).Target
$sourceArgument = $captureTclFile -replace '\\', '/'

Write-Output "Installed ${ProjectName}:"
foreach ($item in $plan) { Write-Output "  $($item.Target)" }
Write-Output "  manifest: $manifestPath"
Write-Output ''
Write-Output 'In the Capture Tcl console, load and start the bridge explicitly:'
Write-Output "  source $sourceArgument"
if ($EnableAutoStart) {
    Write-Output ''
    Write-Output 'Auto-start is enabled: the bridge opens whenever Capture launches.'
    Write-Output 'Run uninstall.ps1, or delete the auto-start file, to require an'
    Write-Output 'explicit start again:'
    Write-Output "  $autoStartTarget"
} else {
    Write-Output '  CaptureAiBridgeStart'
    Write-Output '  CaptureAiBridgeStatus'
}
if ($null -ne $autoStartSource) { Remove-Item -LiteralPath $autoStartSource -Force }
