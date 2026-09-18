[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Prefer the SDK build whenever a .NET SDK is installed. The Add-Type path below
# is a true fallback for SDK-less hosts and should not be mixed with SDK-built
# assemblies in the same long-lived PowerShell runspace.
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

$runtimeRoot = Join-Path $PSScriptRoot '../../Runtime/KubeShell.Runtime'
$runtimeDll = Join-Path $runtimeRoot 'bin/Release/net8.0/KubeShell.Runtime.dll'
if (-not (Test-Path -LiteralPath $runtimeDll)) { $runtimeDll = & (Join-Path $runtimeRoot 'build-with-pwsh.ps1') | Select-Object -Last 1 }
$sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs' -File -Recurse | Sort-Object FullName | ForEach-Object FullName)
$outputDir = Join-Path $PSScriptRoot 'bin/Release/net8.0'
$output = Join-Path $outputDir 'KubeShell.KubectlProcess.dll'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
# Add-Type compiles the source files directly and does not read Nullable/LangVersion
# from the SDK-style .csproj. Keep the fallback compiler semantics aligned with dotnet build.
$compilerOptions = @('/nullable:enable', '/langversion:latest')

# Supplying -ReferencedAssemblies replaces Add-Type's normal framework reference set on
# PowerShell 6+. Compile against PowerShell's reference assemblies and add Runtime to that
# set; otherwise ordinary BCL namespaces such as System.Linq disappear from compilation.
$refDir = Join-Path $PSHOME 'ref'
if (Test-Path -LiteralPath $refDir) {
    $platformReferences = @(
        Get-ChildItem -LiteralPath $refDir -Filter '*.dll' -File |
            Sort-Object FullName |
            ForEach-Object FullName
    )
}
else {
    # Defensive fallback for hosts that do not ship $PSHOME/ref.
    $trustedPlatformAssemblies = [AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES')
    if ([string]::IsNullOrWhiteSpace([string]$trustedPlatformAssemblies)) {
        throw 'Unable to locate .NET reference assemblies for the Add-Type fallback build.'
    }
    $platformReferences = @(
        ([string]$trustedPlatformAssemblies -split [IO.Path]::PathSeparator) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    )
}
$references = @($platformReferences + $runtimeDll | Select-Object -Unique)

Add-Type -Path $sources -ReferencedAssemblies $references -CompilerOptions $compilerOptions -OutputAssembly $output -OutputType Library
Write-Output $output
