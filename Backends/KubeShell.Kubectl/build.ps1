[CmdletBinding()]
param(
    [string] $Configuration = 'Release',
    [switch] $BuildHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build/BuildHelpers.ps1')
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dotnet = Get-Command dotnet -ErrorAction Stop

Invoke-KubeDotNetBuild -Project (Join-Path $PSScriptRoot 'KubeShell.Kubectl.csproj') -Configuration $Configuration
$outputDir = Join-Path $PSScriptRoot "bin/$Configuration/net8.0"

if ($BuildHost) {
    $hostPath = & (Join-Path $root 'native/kubeshell-kubectl/build.ps1') | Select-Object -Last 1
    $rid = Split-Path -Leaf (Split-Path -Parent $hostPath)
    $nativeDir = Join-Path $outputDir "runtimes/$rid/native"
    New-Item -ItemType Directory -Path $nativeDir -Force | Out-Null
    Copy-Item -LiteralPath $hostPath -Destination (Join-Path $nativeDir (Split-Path -Leaf $hostPath)) -Force
}

Write-Output (Join-Path $outputDir 'KubeShell.Kubectl.dll')
