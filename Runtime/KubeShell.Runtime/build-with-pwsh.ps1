[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Prefer the SDK build whenever a .NET SDK is installed. Add-Type is intentionally
# reserved for SDK-less hosts because assemblies loaded by Add-Type remain in the
# current PowerShell process and can pollute later test/build runs.
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$hasDotNetSdk = $false
if ($dotnet) {
    $installedSdks = @(& $dotnet.Source --list-sdks 2>$null)
    $hasDotNetSdk = ($LASTEXITCODE -eq 0 -and $installedSdks.Count -gt 0)
}

if ($hasDotNetSdk) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Configuration Release
    return
}

$sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs' -File -Recurse | Sort-Object FullName | ForEach-Object FullName)
if ($sources.Count -eq 0) { throw 'KubeShell.Runtime C# sources were not found.' }
$outputDir = Join-Path $PSScriptRoot 'bin/Release/net8.0'
$output = Join-Path $outputDir 'KubeShell.Runtime.dll'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }

# Add-Type compiles the source files directly and does not read Nullable/LangVersion
# from the SDK-style .csproj. Keep the fallback compiler semantics aligned with dotnet build.
$compilerOptions = @('/nullable:enable', '/langversion:latest')
Add-Type -Path $sources -CompilerOptions $compilerOptions -OutputAssembly $output -OutputType Library
Write-Output $output
