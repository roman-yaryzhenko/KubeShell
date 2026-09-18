[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$approvedVerbs = [Collections.Generic.HashSet[string]]::new(
    [string[]](Get-Verb | ForEach-Object Verb),
    [StringComparer]::OrdinalIgnoreCase
)

function Assert-KubeApprovedVerbs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleName)

    $unapproved = @(
        Get-Command -Module $ModuleName -CommandType Function,Alias |
            Where-Object Name -Like '*-*' |
            ForEach-Object {
                $verb = ($_.Name -split '-',2)[0]
                if (-not $approvedVerbs.Contains($verb)) { $_.Name }
            }
    )

    if ($unapproved.Count -gt 0) {
        throw "Module '$ModuleName' exports commands with unapproved PowerShell verbs: $($unapproved -join ', ')"
    }
}

$manifestPath = Join-Path $Root 'KubeShell.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Import-Module $manifestPath -Force
Assert-KubeApprovedVerbs -ModuleName KubeShell

if ($manifest.ExportedFunctions.Count -lt 50) {
    throw "Unexpectedly small public API: $($manifest.ExportedFunctions.Count) exported functions."
}

foreach ($optional in @('KubeShell.Api','KubeShell.Flux','KubeShell.Helm')) {
    $path = Join-Path $Root "Optional/$optional/$optional.psd1"
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing optional module manifest: $path" }
    Test-ModuleManifest -Path $path -ErrorAction Stop | Out-Null
    Import-Module $path -Force
    Assert-KubeApprovedVerbs -ModuleName $optional
}

Write-Host "Runtime manifest/import and approved-verb checks passed on PowerShell $($PSVersionTable.PSVersion)."
