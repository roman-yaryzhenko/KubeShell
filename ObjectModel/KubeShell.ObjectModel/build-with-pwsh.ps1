[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$dotnet=Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet -and @(& $dotnet.Source --list-sdks 2>$null).Count -gt 0) { & (Join-Path $PSScriptRoot 'build.ps1'); return }
$runtimeRoot=Join-Path $PSScriptRoot '../../Runtime/KubeShell.Runtime'
$runtimeDll=Join-Path $runtimeRoot 'bin/Release/net8.0/KubeShell.Runtime.dll'
if (-not (Test-Path -LiteralPath $runtimeDll)) { $runtimeDll=& (Join-Path $runtimeRoot 'build-with-pwsh.ps1') | Select-Object -Last 1 }
$sources=@(Get-ChildItem (Join-Path $PSScriptRoot 'src') -Filter '*.cs' -File -Recurse | Sort-Object FullName | ForEach-Object FullName)
$outDir=Join-Path $PSScriptRoot 'bin/Release/net8.0'; New-Item -ItemType Directory $outDir -Force | Out-Null
$out=Join-Path $outDir 'KubeShell.ObjectModel.dll'; if (Test-Path $out) { Remove-Item $out -Force }
$refDir=Join-Path $PSHOME 'ref'
if (Test-Path $refDir) { $platform=@(Get-ChildItem $refDir -Filter '*.dll' -File | ForEach-Object FullName) }
else { $platform=@(([string][AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator) | Where-Object { $_ }) }
Add-Type -Path $sources -ReferencedAssemblies @($platform+$runtimeDll|Select-Object -Unique) -CompilerOptions @('/nullable:enable','/langversion:latest') -OutputAssembly $out -OutputType Library
$out
