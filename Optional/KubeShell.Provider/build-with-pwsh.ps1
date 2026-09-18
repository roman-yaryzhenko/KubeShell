[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runtimeDll = & (Join-Path $root 'Runtime/KubeShell.Runtime/build-with-pwsh.ps1') | Select-Object -Last 1
$objectModelDll = & (Join-Path $root 'ObjectModel/KubeShell.ObjectModel/build-with-pwsh.ps1') | Select-Object -Last 1
$hostingDll = & (Join-Path $root 'Hosting/KubeShell.Hosting/build-with-pwsh.ps1') | Select-Object -Last 1

$sources = @(Get-ChildItem (Join-Path $PSScriptRoot 'src') -Filter '*.cs' -File -Recurse | Sort-Object FullName | ForEach-Object FullName)
$outputDir = Join-Path $PSScriptRoot 'bin/Release/net8.0'
$output = Join-Path $outputDir 'KubeShell.Provider.dll'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
if (Test-Path $output) { Remove-Item $output -Force }

$refDir = Join-Path $PSHOME 'ref'
if (Test-Path $refDir) {
    $platform = @(Get-ChildItem $refDir -Filter '*.dll' -File | ForEach-Object FullName)
}
else {
    $platform = @(([string][AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator) | Where-Object { $_ })
}
$sma = [Management.Automation.PSObject].Assembly.Location
$references = @($platform + $sma + $runtimeDll + $objectModelDll + $hostingDll | Select-Object -Unique)
# PowerShell 7.6 is hosted on .NET 10 while the reusable KubeShell semantic assemblies
# deliberately remain net8.0. Roslyn reports CS1701/CS1702 when it unifies their
# System.Runtime 8 reference with the host's System.Runtime 10 reference. This is
# expected framework roll-forward, not a source warning; suppress only those two codes.
$compilerOptions = @('/nullable:enable','/langversion:latest')
if ([Environment]::Version.Major -gt 8) {
    $compilerOptions += '/nowarn:1701,1702'
}
Add-Type -Path $sources -ReferencedAssemblies $references -CompilerOptions $compilerOptions -OutputAssembly $output -OutputType Library
foreach ($dependency in @($runtimeDll, $objectModelDll, $hostingDll)) {
    Copy-Item -LiteralPath $dependency -Destination $outputDir -Force
}
Write-Output $output
