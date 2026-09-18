[CmdletBinding()]
param([ValidateSet('Debug','Release')][string]$Configuration='Release')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build/BuildHelpers.ps1')

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue

# SDK builds are portable artifacts: the project compiles against PowerShell Standard,
# independent of the PowerShell/.NET runtime hosting this build. Add-Type remains an
# SDK-less local fallback only and is never used by build/Package.ps1.
if (-not $dotnet) {
    & (Join-Path $PSScriptRoot 'build-with-pwsh.ps1')
    return
}

$project = Join-Path $PSScriptRoot 'KubeShell.Provider.csproj'
Invoke-KubeDotNetBuild -Project $project -Configuration $Configuration

$out = Join-Path $PSScriptRoot "bin/$Configuration/net8.0/KubeShell.Provider.dll"
$bundledSma = Join-Path (Split-Path -Parent $out) 'System.Management.Automation.dll'
if (Test-Path -LiteralPath $bundledSma -PathType Leaf) {
    throw "Provider build must not bundle System.Management.Automation: $bundledSma"
}
Write-Output $out
