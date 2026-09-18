[CmdletBinding()]
param([ValidateSet('Debug','Release')][string]$Configuration='Release')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build/BuildHelpers.ps1')
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 8 SDK is required.' }
$project = Join-Path $PSScriptRoot 'KubeShell.Hosting.csproj'
Invoke-KubeDotNetBuild -Project $project -Configuration $Configuration
Join-Path $PSScriptRoot "bin/$Configuration/net8.0/KubeShell.Hosting.dll"
