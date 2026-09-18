[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-KubeText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Required contract-audit path is missing: $Path" }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Content -LiteralPath $Path -Raw
    }
    return ((Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.cs' | Sort-Object FullName | ForEach-Object {
        Get-Content -LiteralPath $_.FullName -Raw
    }) -join "`n")
}

function Assert-KubeMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Message
    )
    if ($Text -notmatch $Pattern) { throw "[$Id] $Message" }
}

function Assert-KubeNoMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Message
    )
    if ($Text -match $Pattern) { throw "[$Id] $Message" }
}

# PowerShell syntax is part of local S evidence and uses the parser shipped with the
# PowerShell that is actually running the matrix. tree-sitter/Node remain supplemental
# development/CI audits and are deliberately not a local contract-runner dependency.
Write-Host '[matrix:S:parse] PowerShell parser + formatting XML'
& (Join-Path $PSScriptRoot 'Parse.ps1') -Root $Root
Write-Host '[matrix:S:contracts] frozen source-boundary assertions'

$providerProject = Get-KubeText (Join-Path $Root 'Optional/KubeShell.Provider/KubeShell.Provider.csproj')
$providerSource = Get-KubeText (Join-Path $Root 'Optional/KubeShell.Provider/src')
$objectModelProject = Get-KubeText (Join-Path $Root 'ObjectModel/KubeShell.ObjectModel/KubeShell.ObjectModel.csproj')
$objectModelSource = Get-KubeText (Join-Path $Root 'ObjectModel/KubeShell.ObjectModel/src')
$runtimeProject = Get-KubeText (Join-Path $Root 'Runtime/KubeShell.Runtime/KubeShell.Runtime.csproj')
$runtimeSource = Get-KubeText (Join-Path $Root 'Runtime/KubeShell.Runtime/src')
$hostingSource = Get-KubeText (Join-Path $Root 'Hosting/KubeShell.Hosting/src')
$packageSource = Get-KubeText (Join-Path $Root 'build/Package.ps1')

# A1 / K8 — Provider is a framework adapter only.
Assert-KubeMatch -Id 'A1' -Text $providerProject -Pattern 'KubeShell\.ObjectModel\.csproj' -Message 'Provider does not reference ObjectModel.'
Assert-KubeMatch -Id 'A1' -Text $providerProject -Pattern 'KubeShell\.Runtime\.csproj' -Message 'Provider does not reference Runtime.'
Assert-KubeMatch -Id 'A1' -Text $providerProject -Pattern 'KubeShell\.Hosting\.csproj' -Message 'Provider does not reference Hosting.'
Assert-KubeNoMatch -Id 'A1/K8' -Text $providerSource -Pattern '(?m)KubeShell\.Backends|KubeBackendRouter|ProcessStartInfo|System\.Diagnostics\.Process|PowerShell\.Create\s*\(|RunspaceFactory|kubeshell-kubectl-host|FileName\s*=\s*["'']kubectl["'']' -Message 'Provider contains concrete backend/process/nested-runspace execution knowledge.'

# A2 / G5 — ObjectModel is frontend-neutral and depends only on Runtime.
Assert-KubeMatch -Id 'A2' -Text $objectModelProject -Pattern 'KubeShell\.Runtime\.csproj' -Message 'ObjectModel does not reference Runtime.'
Assert-KubeNoMatch -Id 'A2' -Text $objectModelProject -Pattern 'KubeShell\.Hosting\.csproj|KubeShell\.Provider\.csproj|Backends/' -Message 'ObjectModel project references an outer/concrete layer.'
Assert-KubeNoMatch -Id 'A2/G5' -Text $objectModelSource -Pattern 'System\.Management\.Automation|KubeShell\.Hosting|KubeShell\.Backends|ProcessStartInfo|PowerShell\.Create\s*\(|RunspaceFactory' -Message 'ObjectModel contains PowerShell/Hosting/backend-specific dependencies.'

# A3 — Runtime owns contracts and has no concrete/backend/frontend dependency.
Assert-KubeNoMatch -Id 'A3' -Text $runtimeProject -Pattern '<ProjectReference|<PackageReference|System\.Management\.Automation|KubernetesClient' -Message 'Runtime project acquired an outer/concrete dependency.'
Assert-KubeNoMatch -Id 'A3' -Text $runtimeSource -Pattern 'System\.Management\.Automation|KubeShell\.Backends|KubernetesClient' -Message 'Runtime source contains a frontend or concrete-backend dependency.'

# A4 — Hosting may compose concrete backends internally, but its public API exposes only Runtime semantics.
$hostingPublicSurface = (($hostingSource -split "`n") | Where-Object { $_ -match '^\s*public\s' }) -join "`n"
Assert-KubeNoMatch -Id 'A4' -Text $hostingPublicSurface -Pattern 'IKubeBackend|KubeBackendRouter|IReadOnlyList<\s*IKubeBackend' -Message 'Hosting exposes backend/router objects on its public API.'
Assert-KubeMatch -Id 'A4' -Text $hostingSource -Pattern 'new\s+KubeBackendRouter\s*\(' -Message 'Hosting no longer owns backend-router composition.'
Assert-KubeMatch -Id 'A4' -Text $hostingPublicSurface -Pattern 'IKubeResourceClient\s+ResourceClient' -Message 'Hosting does not expose Runtime semantic resource clients.'

# K2 — semantic locator, rather than a PowerShell path string, is the navigation/cache identity.
Assert-KubeMatch -Id 'K2' -Text $providerSource -Pattern 'KubeNodeLocator\s+RootLocator' -Message 'Provider drive state does not retain a semantic RootLocator.'
Assert-KubeMatch -Id 'K2' -Text $providerSource -Pattern 'ResolveChildAsync\s*\(' -Message 'Provider path traversal is not delegated segment-by-segment to ObjectModel.'
Assert-KubeMatch -Id 'K2' -Text $objectModelSource -Pattern 'ConcurrentDictionary<\s*KubeNodeLocator\s*,' -Message 'ObjectModel navigation cache is not keyed by semantic locators.'

# L5 — the SDK artifact is compiled against PowerShell Standard, not the build host SMA.
Assert-KubeMatch -Id 'L5' -Text $providerProject -Pattern 'PackageReference\s+Include=["'']PowerShellStandard\.Library["'']' -Message 'Provider lacks the portable PowerShell Standard compile-time contract.'
Assert-KubeNoMatch -Id 'L5' -Text $providerProject -Pattern '<Reference\s+Include=["'']System\.Management\.Automation["'']|\$\(PowerShellHome\)|\$PSHOME' -Message 'Provider SDK project is bound to build-host System.Management.Automation.'

# L6 source invariant — executable B evidence still seeds a stale sentinel and inspects the archive.
Assert-KubeMatch -Id 'L6' -Text $packageSource -Pattern "'bin','obj'" -Message 'Package source staging does not explicitly exclude bin/obj.'
Assert-KubeMatch -Id 'L6' -Text $packageSource -Pattern 'Copy-KubeBuildOutput' -Message 'Package does not stage fresh build outputs through an explicit allow-list.'
Assert-KubeMatch -Id 'L6' -Text $packageSource -Pattern '\$unexpectedBinFiles' -Message 'Package lacks the staged unexpected-bin postcondition.'
Assert-KubeMatch -Id 'L6' -Text $packageSource -Pattern 'Where-Object \{ \$_.Name -in @\(''bin'',''obj''\) \}' -Message 'Package does not clean pre-existing project bin/obj directories before building.'

Write-Host 'PowerShell-native frozen-matrix static contract audit passed (A1-A4, G5, K2, K8, L5-L6 source lanes).'

[pscustomobject]@{
    PSTypeName = 'KubeShell.ContractStaticResult'
    Status = 'PASS'
    MatrixIds = @('A1','A2','A3','A4','G5','K2','K8','L5','L6')
    PowerShellFilesParsed = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object Extension -In '.ps1','.psm1','.psd1').Count
    ExtendedNodeAudits = 'SUPPLEMENTAL-NOT-REQUIRED'
}
