[CmdletBinding()]
param(
    [string] $PackageVersion = '0.3.0-alpha11',
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [switch] $SkipTests,
    [switch] $SkipProviderBuild,
    [switch] $BuildManagedBackend,
    [switch] $SkipManagedBackendBuild,
    [switch] $SkipKubectlBackendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# [L6] Packaging must be a function of this build, not of stale artifacts left by an earlier
# checkout/build. Clean every project output directory before compiling, and later stage source
# separately from the known fresh outputs produced below.
$artifactRoots = @('Runtime','ObjectModel','Hosting','Backends','Libraries','Optional','Tests/Fixtures')
foreach ($relativeRoot in $artifactRoots) {
    $artifactRoot = Join-Path $root $relativeRoot
    if (-not (Test-Path -LiteralPath $artifactRoot -PathType Container)) { continue }
    @(Get-ChildItem -LiteralPath $artifactRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('bin','obj') } |
        Sort-Object { $_.FullName.Length } -Descending) |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}
# Build Runtime/process backend before importing KubeShell in tests. The compatibility
# wrappers delegate to SDK builds when dotnet is present and use Add-Type only on SDK-less hosts.
$runtimeAssembly = & (Join-Path $root 'Runtime/KubeShell.Runtime/build-with-pwsh.ps1') | Select-Object -Last 1
$objectModelAssembly = & (Join-Path $root 'ObjectModel/KubeShell.ObjectModel/build-with-pwsh.ps1') | Select-Object -Last 1
$hostingAssembly = & (Join-Path $root 'Hosting/KubeShell.Hosting/build-with-pwsh.ps1') | Select-Object -Last 1
$processBackendAssembly = & (Join-Path $root 'Backends/KubeShell.KubectlProcess/build-with-pwsh.ps1') | Select-Object -Last 1

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET 8 SDK or newer is required to package managed YAML support.' }
& (Join-Path $root 'Libraries/KubeShell.Serialization/build.ps1') | Out-Null

if ($BuildManagedBackend -and $SkipManagedBackendBuild) {
    throw '-BuildManagedBackend and -SkipManagedBackendBuild cannot be used together.'
}
# Managed KubernetesClient is the primary packaged semantic backend. -BuildManagedBackend remains
# accepted for compatibility; building is now the default unless explicitly skipped for source-only work.
if (-not $SkipManagedBackendBuild) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET 8 SDK is required to package the primary managed KubernetesClient backend. Use -SkipManagedBackendBuild only for a source-only package.'
    }
    & (Join-Path $root 'Backends/KubeShell.KubernetesClient/build.ps1') | Out-Null
}

if (-not $SkipKubectlBackendBuild) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET 8 SDK is required to package KubeShell.Kubectl. Use -SkipKubectlBackendBuild only for a source-only package.'
    }
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        throw 'Go 1.26+ is required to package kubeshell-kubectl-host. Use -SkipKubectlBackendBuild only for a source-only package.'
    }
    & (Join-Path $root 'Backends/KubeShell.Kubectl/build.ps1') -BuildHost | Out-Null
}

if (-not $SkipTests) {
    & (Join-Path $root 'Tests/Run.ps1') -RequirePester
}

if (-not $SkipProviderBuild) {
    # Packaging always has dotnet available above, so Provider build.ps1 emits the portable
    # net8.0 artifact compiled against PowerShell Standard rather than this build host's SMA.
    & (Join-Path $root 'Optional/KubeShell.Provider/build.ps1') | Out-Null
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stageRoot = Join-Path $OutputDirectory '.stage'
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }

$packageRoot = Join-Path $stageRoot "KubeShell-$PackageVersion"
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

# [L6] Source staging deliberately excludes every nested bin/obj. Build artifacts are copied
# afterwards from an explicit allow-list, so an unproduced stale DLL cannot enter the archive.
$excludedDirectoryNames = @('.git','.github','dist','node_modules','bin','obj','build')
function Copy-KubeSourceTree {
    param([Parameter(Mandatory)][string] $Source, [Parameter(Mandatory)][string] $Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.PSIsContainer) {
            if ($item.Name -in $excludedDirectoryNames) { continue }
            Copy-KubeSourceTree -Source $item.FullName -Destination (Join-Path $Destination $item.Name)
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Force
    }
}
Copy-KubeSourceTree -Source $root -Destination $packageRoot

function Copy-KubeBuildOutput {
    param([Parameter(Mandatory)][string] $RelativePath)
    $source = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Expected fresh build output is missing: $source"
    }
    $destination = Join-Path $packageRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

Copy-KubeBuildOutput 'Runtime/KubeShell.Runtime/bin/Release/net8.0'
Copy-KubeBuildOutput 'ObjectModel/KubeShell.ObjectModel/bin/Release/net8.0'
Copy-KubeBuildOutput 'Hosting/KubeShell.Hosting/bin/Release/net8.0'
Copy-KubeBuildOutput 'Backends/KubeShell.KubectlProcess/bin/Release/net8.0'
Copy-KubeBuildOutput 'Libraries/KubeShell.Serialization/bin/Release/net8.0'
if (-not $SkipManagedBackendBuild) { Copy-KubeBuildOutput 'Backends/KubeShell.KubernetesClient/bin/Release/net8.0' }
if (-not $SkipKubectlBackendBuild) { Copy-KubeBuildOutput 'Backends/KubeShell.Kubectl/bin/Release/net8.0' }
if (-not $SkipProviderBuild) { Copy-KubeBuildOutput 'Optional/KubeShell.Provider/bin/Release/net8.0' }

# [L6] Assert the staged tree contains no obj directories and no bin trees outside the explicit
# build-output allow-list above. This catches accidental future regressions in staging logic.
$allowedBinRoots = @(
    'Runtime/KubeShell.Runtime/bin/Release/net8.0',
    'ObjectModel/KubeShell.ObjectModel/bin/Release/net8.0',
    'Hosting/KubeShell.Hosting/bin/Release/net8.0',
    'Backends/KubeShell.KubectlProcess/bin/Release/net8.0',
    'Libraries/KubeShell.Serialization/bin/Release/net8.0'
)
if (-not $SkipManagedBackendBuild) { $allowedBinRoots += 'Backends/KubeShell.KubernetesClient/bin/Release/net8.0' }
if (-not $SkipKubectlBackendBuild) { $allowedBinRoots += 'Backends/KubeShell.Kubectl/bin/Release/net8.0' }
if (-not $SkipProviderBuild) { $allowedBinRoots += 'Optional/KubeShell.Provider/bin/Release/net8.0' }
$unexpectedObj = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Recurse -Force | Where-Object Name -EQ 'obj')
if ($unexpectedObj.Count -gt 0) { throw 'Package staging contains an unexpected obj directory.' }
$unexpectedBinFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force | Where-Object {
    $relative = [IO.Path]::GetRelativePath($packageRoot, $_.FullName).Replace('\', '/')
    if ($relative -notmatch '(^|/)bin/') { return $false }
    foreach ($allowed in $allowedBinRoots) {
        if ($relative.StartsWith($allowed + '/', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
})
if ($unexpectedBinFiles.Count -gt 0) {
    throw "Package staging contains unexpected build artifacts: $($unexpectedBinFiles[0].FullName)"
}

if (-not $SkipManagedBackendBuild) {
    $packagedManaged = Join-Path $packageRoot 'Backends/KubeShell.KubernetesClient/bin/Release/net8.0/KubeShell.KubernetesClient.dll'
    $packagedOfficialClient = Join-Path $packageRoot 'Backends/KubeShell.KubernetesClient/bin/Release/net8.0/KubernetesClient.dll'
    if (-not (Test-Path -LiteralPath $packagedManaged -PathType Leaf) -or -not (Test-Path -LiteralPath $packagedOfficialClient -PathType Leaf)) {
        throw 'Packaged primary managed backend is incomplete.'
    }
}

if (-not $SkipKubectlBackendBuild) {
    $packagedBackend = Join-Path $packageRoot 'Backends/KubeShell.Kubectl/bin/Release/net8.0/KubeShell.Kubectl.dll'
    if (-not (Test-Path -LiteralPath $packagedBackend -PathType Leaf)) {
        throw "Packaged kubectl backend is missing: $packagedBackend"
    }
    $packagedHosts = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'Backends/KubeShell.Kubectl/bin/Release/net8.0/runtimes') -Filter 'kubeshell-kubectl-host*' -File -Recurse -ErrorAction SilentlyContinue)
    if ($packagedHosts.Count -eq 0) { throw 'Packaged kubectl backend contains no native host executable.' }
}

$archive = Join-Path $OutputDirectory "KubeShell-$PackageVersion.zip"
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Compress-Archive -Path $packageRoot -DestinationPath $archive -CompressionLevel Optimal

$hash = Get-FileHash -LiteralPath $archive -Algorithm SHA256
Remove-Item -LiteralPath $stageRoot -Recurse -Force

[pscustomobject]@{
    PSTypeName = 'KubeShell.Package'
    Path       = $archive
    Sha256     = $hash.Hash.ToLowerInvariant()
    Version    = $PackageVersion
}
