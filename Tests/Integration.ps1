[CmdletBinding()]
param(
    [string]$ModulePath = (Join-Path $PSScriptRoot '..' 'KubeShell.psd1'),
    [string]$Namespace = 'default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:KUBESHELL_RUN_INTEGRATION -ne '1') {
    Write-Host 'Integration checks skipped. Set KUBESHELL_RUN_INTEGRATION=1 to run against the current kubectl context.'
    return
}

Import-Module $ModulePath -Force

$context = Get-KubeContext | Where-Object Current | Select-Object -First 1
if (-not $context) { throw 'No current Kubernetes context was found.' }

$namespaceObject = Get-KubeNamespace -Name $Namespace
if (-not $namespaceObject) { throw "Namespace '$Namespace' was not returned by the API." }

# Read-only checks deliberately avoid making any cluster changes.
$null = @(Get-KubePod -Namespace $Namespace)
$access = Test-KubeAccess get pods -Namespace $Namespace
if ($null -eq $access.Allowed) { throw 'RBAC access check did not return a structured result.' }

Write-Host "KubeShell integration checks passed against context '$($context.Name)'."
