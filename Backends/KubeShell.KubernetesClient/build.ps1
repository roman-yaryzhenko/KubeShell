[CmdletBinding()]
param([ValidateSet('Debug','Release')][string]$Configuration='Release')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build/BuildHelpers.ps1')
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'dotnet SDK is required to restore the published KubernetesClient 19.0.2 package and build the managed backend.' }
Invoke-KubeDotNetBuild -Project (Join-Path $PSScriptRoot 'KubeShell.KubernetesClient.csproj') -Configuration $Configuration

$outputRoot = Join-Path $PSScriptRoot "bin/$Configuration/net8.0"
$backendDll = Join-Path $outputRoot 'KubeShell.KubernetesClient.dll'
$officialClientDll = Join-Path $outputRoot 'KubernetesClient.dll'
if (-not (Test-Path -LiteralPath $officialClientDll -PathType Leaf)) {
    throw 'KubernetesClient.dll was not copied to the managed backend output. CopyLocalLockFileAssemblies must remain enabled for this PowerShell-loaded class library.'
}
Write-Output $backendDll
