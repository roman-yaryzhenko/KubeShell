[CmdletBinding()]
param([string]$ModulePath = (Join-Path $PSScriptRoot '..' 'KubeShell.psd1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $ModulePath -Force

$required = @(
    'Get-KubePod','Get-KubeDeployment','Get-KubeResource','Get-KubeLog','Enter-KubePod',
    'Set-KubeManifest','Test-KubeManifest','Test-KubePod','Get-KubeNodeAllocation',
    'Get-KubeConfigSet','New-KubeConfigSet','Get-KubeProfile','Use-KubeProfile','Get-KubeSession',
    'Set-KubeContext','Set-KubeNamespace','Enable-KubeCompletion'
)
foreach ($name in $required) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing exported command: $name"
    }
}

# These checks are deliberately cluster-free.
$pod = [pscustomobject]@{
    apiVersion='v1'; kind='Pod'
    metadata=[pscustomobject]@{ name='demo'; namespace='test'; creationTimestamp=[datetimeoffset]::Now.AddMinutes(-5).ToString('o') }
    spec=[pscustomobject]@{ nodeName='node-1'; containers=@([pscustomobject]@{ name='app'; image='demo:v1' }) }
    status=[pscustomobject]@{ phase='Running'; containerStatuses=@([pscustomobject]@{ name='app'; ready=$true; restartCount=2 }) }
}

$corePath = Join-Path $PSScriptRoot '..' 'Modules/KubeShell.Core/KubeShell.Core.psd1'
Import-Module $corePath -Force
$converted = ConvertTo-KubeObject $pod
if ($converted.Name -ne 'demo' -or $converted.Ready -ne '1/1' -or $converted.Restarts -ne 2 -or -not $converted.Healthy) {
    throw 'Pod object enrichment smoke test failed.'
}
if ([math]::Abs((ConvertFrom-KubeCpuQuantity '250m') - 0.25) -gt 0.000001) { throw 'CPU quantity conversion failed.' }
if ((ConvertFrom-KubeMemoryQuantity '512Mi') -ne 512MB) { throw 'Memory quantity conversion failed.' }


$wireJson = ConvertTo-KubeWireJson -InputObject $converted -ForApply
$wire = $wireJson | ConvertFrom-Json -Depth 100

# PowerShell's -match is case-insensitive by default. Kubernetes legitimately contains
# metadata.name, so a regex looking for "Name" would report a false positive.
# Inspect only root properties and compare their names case-sensitively instead.
$wireRootProperties = @($wire.PSObject.Properties.Name)
foreach ($propertyName in @('Name','Healthy','AgeText')) {
    if ($wireRootProperties -ccontains $propertyName) {
        throw "KubeShell convenience property '$propertyName' leaked into wire JSON."
    }
}
if ($wire.metadata.name -ne 'demo' -or $wire.spec.nodeName -ne 'node-1') {
    throw 'Wire object lost Kubernetes API fields.'
}

# WhatIf must not require kubectl when the complete identity is already in the pipeline object.
$converted | Remove-KubePod -WhatIf | Out-Null

Write-Host 'KubeShell smoke checks passed.'
