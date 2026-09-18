[CmdletBinding()]
param([ValidateSet('Debug','Release')][string]$Configuration='Release')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build/BuildHelpers.ps1')
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 8 SDK or newer is required to build KubeShell.Serialization.' }

Invoke-KubeDotNetBuild -Project (Join-Path $PSScriptRoot 'KubeShell.Serialization.csproj') -Configuration $Configuration

$output = Join-Path $PSScriptRoot "bin/$Configuration/net8.0"
$assembly = Join-Path $output 'KubeShell.Serialization.dll'
$yaml = Join-Path $output 'YamlDotNet.dll'
if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw "Serialization assembly was not produced: $assembly" }
if (-not (Test-Path -LiteralPath $yaml -PathType Leaf)) { throw 'YamlDotNet.dll was not copied next to KubeShell.Serialization.dll.' }
Write-Output $assembly
