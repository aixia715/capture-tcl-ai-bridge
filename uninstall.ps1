<#
.SYNOPSIS
    Removes the Capture Tcl AI bridge runtime files recorded by install.ps1.

.DESCRIPTION
    Reads %LOCALAPPDATA%\capture-tcl-ai-bridge\install.json and deletes only the
    files it proves this project installed. The manifest is not trusted blindly:
    the deletable paths are reconstructed from the recorded target directories,
    and every recorded entry must match one of them exactly. Any
    surprise - a foreign project, an unsupported schema, a relative path, a
    duplicate, or a path outside the targets - aborts before a single deletion.

    A file whose content no longer matches the manifest was edited after
    installation, so it is kept and left in the manifest unless -ForceModified
    is given. Target directories are never removed.

.PARAMETER ForceModified
    Also delete owned files whose content no longer matches the manifest.
#>
param([switch]$ForceModified)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectName = 'capture-tcl-ai-bridge'
$SchemaVersion = 1
$ServerName = 'capture_tcl_bridge_server.py'
$CliName = 'capture_tcl_cli.py'
$McpName = 'capture_mcp_server.py'
$TclName = 'captureAiBridge.tcl'
$AutoStartName = 'captureAiBridgeAutoStart.tcl'

function Stop-Uninstall {
    param([string]$Message)
    [Console]::Error.WriteLine("uninstall.ps1: $Message")
    exit 1
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

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    $temporary = "$Path.$ProjectName.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $Text, $encoding)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$manifestDirectory = Join-Path $env:LOCALAPPDATA $ProjectName
$manifestPath = Join-Path $manifestDirectory 'install.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Output "$ProjectName is not installed; nothing to remove."
    exit 0
}

try {
    $data = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
} catch {
    Stop-Uninstall "install manifest is not readable JSON: $manifestPath"
}

if ((Get-JsonProperty $data 'schemaVersion') -ne $SchemaVersion) {
    Stop-Uninstall "install manifest has an unsupported schema version: $manifestPath"
}
if ((Get-JsonProperty $data 'project') -ne $ProjectName) {
    Stop-Uninstall "install manifest belongs to another project: $manifestPath"
}

$pythonTarget = Get-JsonProperty $data 'pythonTarget'
$captureTclTarget = Get-JsonProperty $data 'captureTclTarget'
foreach ($value in @($pythonTarget, $captureTclTarget)) {
    if ([string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value)) {
        Stop-Uninstall "install manifest has a target directory that is not absolute."
    }
}
$pythonTarget = [IO.Path]::GetFullPath($pythonTarget)
$captureTclTarget = [IO.Path]::GetFullPath($captureTclTarget)

# The only paths this script may ever delete, rebuilt from the target
# directories rather than taken from the recorded entries. The auto-start
# file is optional, so a manifest may record four entries or five; what
# matters is that nothing outside this set is ever deletable.
$allowed = @{}
foreach ($candidate in @(
        (Join-Path $pythonTarget $ServerName),
        (Join-Path $pythonTarget $CliName),
        (Join-Path $pythonTarget $McpName),
        (Join-Path $captureTclTarget $TclName),
        (Join-Path $captureTclTarget $AutoStartName))) {
    $allowed[$candidate.ToLowerInvariant()] = $candidate
}

$files = @(Get-JsonProperty $data 'files')
if ($files.Count -eq 0) {
    Stop-Uninstall "install manifest records no files: $manifestPath"
}

$entries = @()
$seen = @{}
foreach ($entry in $files) {
    $entryPath = Get-JsonProperty $entry 'path'
    $entryHash = Get-JsonProperty $entry 'sha256'
    if ([string]::IsNullOrWhiteSpace($entryPath) -or
        [string]::IsNullOrWhiteSpace($entryHash)) {
        Stop-Uninstall "install manifest has an incomplete file record; nothing was removed."
    }
    if (-not [IO.Path]::IsPathRooted($entryPath)) {
        Stop-Uninstall "install manifest records a relative path '$entryPath'; nothing was removed."
    }
    $canonical = [IO.Path]::GetFullPath($entryPath)
    $key = $canonical.ToLowerInvariant()
    if (-not $allowed.ContainsKey($key)) {
        Stop-Uninstall (
            "install manifest records '$canonical', which is not one of the " +
            "files this project installs; nothing was removed.")
    }
    if ($seen.ContainsKey($key)) {
        Stop-Uninstall "install manifest records '$canonical' twice; nothing was removed."
    }
    $seen[$key] = $true
    $entries += [pscustomobject]@{
        Path   = $allowed[$key]
        Sha256 = "$entryHash".ToLowerInvariant()
    }
}

$removed = @()
$kept = @()
foreach ($entry in $entries) {
    if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
        continue
    }
    if (-not $ForceModified -and (Get-Sha256 $entry.Path) -ne $entry.Sha256) {
        $kept += $entry
        continue
    }
    Remove-Item -LiteralPath $entry.Path -Force
    $removed += $entry.Path
}

foreach ($path in $removed) { Write-Output "Removed $path" }

if ($kept.Count -eq 0) {
    Remove-Item -LiteralPath $manifestPath -Force
    if (@(Get-ChildItem -LiteralPath $manifestDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $manifestDirectory -Force
    }
    Write-Output "Removed $manifestPath"
    Write-Output "$ProjectName is uninstalled. Its target directories were left in place."
    exit 0
}

$manifest = [ordered]@{
    schemaVersion    = $SchemaVersion
    project          = $ProjectName
    pythonTarget     = $pythonTarget
    captureTclTarget = $captureTclTarget
    files            = @($kept | ForEach-Object {
            [ordered]@{ path = $_.Path; sha256 = $_.Sha256 }
        })
}
Write-TextAtomic $manifestPath (ConvertTo-Json $manifest -Depth 5)

foreach ($entry in $kept) {
    Write-Output ("Kept $($entry.Path); it was modified after installation. " +
        'Re-run with -ForceModified to delete it.')
}
Write-Output "Updated $manifestPath to list only the files that remain."
