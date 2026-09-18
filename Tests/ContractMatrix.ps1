[CmdletBinding()]
param(
    [string] $PackageVersion = '0.3.0-alpha11',
    [string] $PowerShell74Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$matrixPath = Join-Path $root 'docs/CONTRACT-VERIFICATION-MATRIX-V1.md'

$dotnet = Get-Command dotnet -ErrorAction Stop
$go = Get-Command go -ErrorAction Stop
$currentPwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Show-ChildOutput {
    param([object[]] $Output)
    foreach ($entry in @($Output)) {
        if ($null -ne $entry) { Write-Host ($entry.ToString()) }
    }
}

function Get-MatrixIdsFromOutput {
    param(
        [Parameter(Mandatory)][object[]] $Output,
        [Parameter(Mandatory)][ValidateSet('F','P')][string] $Lane
    )
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Output)) {
        if ($null -eq $entry) { continue }
        $text = $entry.ToString()
        $match = [regex]::Match($text, "MATRIX_IDS:${Lane}=(?<ids>[A-L0-9,]+)")
        if (-not $match.Success) { continue }
        foreach ($id in $match.Groups['ids'].Value.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
            $found.Add($id.Trim())
        }
    }
    if ($found.Count -eq 0) { throw "Contract lane $Lane completed without a MATRIX_IDS:$Lane marker." }
    return @($found | Sort-Object -Unique)
}

function Assert-PowerShellLane {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][int] $PowerShellMinor,
        [Parameter(Mandatory)][int] $RuntimeMajor,
        [Parameter(Mandatory)][string] $Label
    )
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "$Label executable was not found: $Executable" }
    $probeOutput = @(& $Executable -NoProfile -Command '[pscustomobject]@{ PowerShell=$PSVersionTable.PSVersion.ToString(); Runtime=[Environment]::Version.ToString() } | ConvertTo-Json -Compress' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Label version probe failed with exit code ${LASTEXITCODE}:`n$($probeOutput -join [Environment]::NewLine)"
    }
    $probe = ($probeOutput | Select-Object -Last 1 | Out-String).Trim() | ConvertFrom-Json
    $psVersion = [version]$probe.PowerShell
    $runtimeVersion = [version]$probe.Runtime
    if ($psVersion.Major -ne 7 -or $psVersion.Minor -ne $PowerShellMinor -or $runtimeVersion.Major -ne $RuntimeMajor) {
        throw "$Label must be PowerShell 7.$PowerShellMinor on .NET $RuntimeMajor; observed PowerShell $psVersion / .NET $runtimeVersion."
    }
    return [pscustomobject]@{ PowerShell = $psVersion; Runtime = $runtimeVersion }
}

$evidence = @{
    S = @()
    F = @()
    P = @()
    B = @()
}

Write-Host '[matrix:S] PowerShell-native frozen-contract source audit'
$staticResult = & (Join-Path $PSScriptRoot 'ContractStatic.ps1') -Root $root
if ($null -eq $staticResult -or $staticResult.Status -ne 'PASS') {
    throw 'PowerShell-native static contract lane did not return PASS.'
}
$evidence.S = @($staticResult.MatrixIds | Sort-Object -Unique)

Write-Host '[matrix:F] cluster-free .NET contract fixture (Node/npm deliberately disabled)'
$fixtureOutput = @(& $currentPwsh -NoProfile -File (Join-Path $PSScriptRoot 'Run.ps1') -RequirePester -SkipNodeAudits 2>&1)
$fixtureExitCode = $LASTEXITCODE
Show-ChildOutput $fixtureOutput
if ($fixtureExitCode -ne 0) {
    throw "F/P baseline suite failed with exit code ${fixtureExitCode}:`n$($fixtureOutput -join [Environment]::NewLine)"
}
$evidence.F = Get-MatrixIdsFromOutput -Output $fixtureOutput -Lane F

Write-Host '[matrix:P] Provider behavior fixture through real Hosting/ObjectModel/Runtime'
$providerOutput = @(& $currentPwsh -NoProfile -File (Join-Path $PSScriptRoot 'ContractProvider.ps1') -Root $root 2>&1)
$providerExitCode = $LASTEXITCODE
Show-ChildOutput $providerOutput
if ($providerExitCode -ne 0) {
    throw "Provider contract fixture failed with exit code ${providerExitCode}:`n$($providerOutput -join [Environment]::NewLine)"
}
$evidence.P = Get-MatrixIdsFromOutput -Output $providerOutput -Lane P

Write-Host '[matrix:L9] deliberate compiler failure must preserve CSxxxx diagnostics'
. (Join-Path $root 'build/BuildHelpers.ps1')
$l9Root = Join-Path ([IO.Path]::GetTempPath()) ('kubeshell-l9-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $l9Root -Force | Out-Null
try {
    $brokenProject = Join-Path $l9Root 'Broken.csproj'
    $brokenSource = Join-Path $l9Root 'Broken.cs'
    Set-Content -LiteralPath $brokenProject -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath $brokenSource -Value 'public sealed class Broken { this is deliberately invalid C#; }'
    $sawExpectedCompilerFailure = $false
    try {
        Invoke-KubeDotNetBuild -Project $brokenProject -Configuration Release | Out-Null
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'dotnet build failed for' -and $message -match 'Broken\.cs' -and $message -match 'CS\d{4}') {
            $sawExpectedCompilerFailure = $true
            Write-Host '[matrix:L9] complete compiler diagnostic preserved.'
        }
        else {
            throw "L9 failed: compiler failure lost its diagnostic payload:`n$message"
        }
    }
    if (-not $sawExpectedCompilerFailure) { throw 'L9 failed: deliberately invalid C# unexpectedly built successfully.' }
    $evidence.P = @($evidence.P + 'L9' | Sort-Object -Unique)
    $evidence.B = @($evidence.B + 'L9' | Sort-Object -Unique)
}
finally {
    if (Test-Path -LiteralPath $l9Root) { Remove-Item -LiteralPath $l9Root -Recurse -Force }
}

# [L6] Seed an output that the current build does not legitimately produce. Packaging must remove
# it before compiling and the sentinel must never appear in the distributable archive.
$sentinelDirectory = Join-Path $root 'Optional/KubeShell.Api/bin/Release/net8.0'
$sentinelName = 'KUBESHELL-STALE-PACKAGE-SENTINEL.txt'
$sentinelPath = Join-Path $sentinelDirectory $sentinelName
New-Item -ItemType Directory -Path $sentinelDirectory -Force | Out-Null
Set-Content -LiteralPath $sentinelPath -Value 'This stale artifact must never enter a KubeShell package.' -NoNewline

Write-Host '[matrix:B] clean full package + managed/native backends + Go host tests'
$packageOutput = @(& (Join-Path $root 'build/Package.ps1') -PackageVersion $PackageVersion -SkipTests 2>&1)
$packageExitCode = $LASTEXITCODE
if ($packageExitCode -ne 0) {
    throw "Full package build failed with exit code ${packageExitCode}:`n$($packageOutput -join [Environment]::NewLine)"
}
$packageResult = @($packageOutput | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains 'KubeShell.Package' } | Select-Object -Last 1)
if ($packageResult.Count -ne 1) { throw 'Package build returned no KubeShell.Package result.' }
$archive = $packageResult[0].Path
if ([string]::IsNullOrWhiteSpace($archive) -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    throw 'Package build did not produce the expected archive.'
}
if (Test-Path -LiteralPath $sentinelPath) { throw 'L6 failed: package build did not clean the stale build sentinel.' }
$evidence.B = @($evidence.B + @('A3','D9','L1','L5','L6','L8') | Sort-Object -Unique)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('kubeshell-contract-matrix-' + [guid]::NewGuid().ToString('N'))
$currentProbe = $null
$ps74Probe = $null
try {
    Expand-Archive -LiteralPath $archive -DestinationPath $temp -Force
    $stale = @(Get-ChildItem -LiteralPath $temp -File -Recurse -Force | Where-Object Name -EQ $sentinelName)
    if ($stale.Count -ne 0) { throw 'L6 failed: stale build sentinel was packaged.' }

    $packageRoot = @(Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1).FullName
    if ([string]::IsNullOrWhiteSpace($packageRoot)) { throw 'Expanded package root was not found.' }
    $rootManifest = Join-Path $packageRoot 'KubeShell.psd1'
    $providerManifest = Join-Path $packageRoot 'Optional/KubeShell.Provider/KubeShell.Provider.psd1'

    Write-Host '[matrix:L3/L7] build/import package under PowerShell 7.6 / .NET 10'
    $currentProbe = Assert-PowerShellLane -Executable $currentPwsh -PowerShellMinor 6 -RuntimeMajor 10 -Label 'Current matrix lane'
    $currentImport = @(& $currentPwsh -NoProfile -Command @"
`$ErrorActionPreference = 'Stop'
& '$root/Optional/KubeShell.Provider/build.ps1' | Out-Null
Import-Module '$rootManifest' -Force
Import-Module '$providerManifest' -Force
Get-Module KubeShell,KubeShell.Provider | Out-Null
"@ 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "PowerShell 7.6/.NET 10 package build/import failed:`n$($currentImport -join [Environment]::NewLine)"
    }
    $evidence.B = @($evidence.B + @('L3','L7') | Sort-Object -Unique)

    if (-not [string]::IsNullOrWhiteSpace($PowerShell74Path)) {
        Write-Host '[matrix:L2/L4] build/import package under PowerShell 7.4 / .NET 8'
        $ps74Probe = Assert-PowerShellLane -Executable $PowerShell74Path -PowerShellMinor 4 -RuntimeMajor 8 -Label 'PowerShell 7.4 matrix lane'
        $ps74Output = @(& $PowerShell74Path -NoProfile -Command @"
`$ErrorActionPreference = 'Stop'
& '$root/Optional/KubeShell.Provider/build.ps1' | Out-Null
Import-Module '$rootManifest' -Force
Import-Module '$providerManifest' -Force
Get-Module KubeShell,KubeShell.Provider | Out-Null
"@ 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "PowerShell 7.4/.NET 8 package build/import failed:`n$($ps74Output -join [Environment]::NewLine)"
        }
        $rootData = Import-PowerShellDataFile -LiteralPath $rootManifest
        $providerData = Import-PowerShellDataFile -LiteralPath $providerManifest
        if ([version]$rootData.PowerShellVersion -gt [version]'7.4' -or [version]$providerData.PowerShellVersion -gt [version]'7.4') {
            throw 'L4 failed: packaged manifests declare a PowerShell minimum newer than 7.4.'
        }
        $evidence.B = @($evidence.B + @('L2','L4') | Sort-Object -Unique)
    }
    else {
        Write-Warning 'PowerShell 7.4 path was not supplied; frozen cells L2 and L4 remain UNVERIFIED.'
    }
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    if (Test-Path -LiteralPath $sentinelPath) { Remove-Item -LiteralPath $sentinelPath -Force }
}

$allowedUnverified = if ([string]::IsNullOrWhiteSpace($PowerShell74Path)) { @('L2','L4') } else { @() }
$ledger = & (Join-Path $PSScriptRoot 'ContractEvidence.ps1') -MatrixPath $matrixPath -Evidence $evidence -AllowedUnverified $allowedUnverified

Write-Host "[matrix] $($ledger.MatrixStatus): $($ledger.PassCount)/$($ledger.TotalCount) cells; S=$($ledger.S), F=$($ledger.F), P=$($ledger.P), B=$($ledger.B)"
if ($ledger.UnverifiedCount -gt 0) { Write-Warning "UNVERIFIED: $($ledger.Unverified -join ',')" }

[pscustomobject]@{
    PSTypeName = 'KubeShell.ContractMatrixRun'
    MatrixStatus = $ledger.MatrixStatus
    PassCount = $ledger.PassCount
    TotalCount = $ledger.TotalCount
    UnverifiedCount = $ledger.UnverifiedCount
    Unverified = @($ledger.Unverified)
    S = $ledger.S
    F = $ledger.F
    P = $ledger.P
    B = $ledger.B
    SupplementalNodeAudits = 'NOT-RUN-BY-DESIGN'
    Archive = $archive
    DotNet = (& $dotnet.Source --version | Select-Object -First 1)
    Go = (& $go.Source version | Select-Object -First 1)
    PowerShell = $currentProbe.PowerShell.ToString()
    Runtime = $currentProbe.Runtime.ToString()
    PowerShell74 = if ($null -eq $ps74Probe) { 'UNVERIFIED' } else { $ps74Probe.PowerShell.ToString() }
    Runtime74 = if ($null -eq $ps74Probe) { 'UNVERIFIED' } else { $ps74Probe.Runtime.ToString() }
}
