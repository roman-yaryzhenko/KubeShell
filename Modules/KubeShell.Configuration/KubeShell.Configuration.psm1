Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Core/KubeShell.Core.psd1') -Scope Local

$script:ConfigSets = @{}
$script:Profiles = @{}

# Configuration persistence, definitions, and session projection remain one adapter module,
# while implementation files separate their independent reasons to change.
$privateScripts = @(
    'Store.ps1'
    'Session.ps1'
    'ConfigSets.ps1'
    'Profiles.ps1'
)
foreach ($privateScript in $privateScripts) {
    . (Join-Path $PSScriptRoot "Private/$privateScript")
}

Import-KubeConfigurationStore
$initialState = Get-KubeExecutionContext
if ($initialState.Source -eq 'Default' -and @($initialState.KubeConfigPaths).Count -eq 0 -and
    [string]::IsNullOrEmpty([string]$initialState.Context) -and
    [string]::IsNullOrWhiteSpace([string]$initialState.Profile) -and
    [string]::IsNullOrWhiteSpace([string]$initialState.ConfigSet)) {
    Initialize-KubeExecutionContext
}

Export-ModuleMember -Function @(
    'Get-KubeConfigurationStorePath',
    'Get-KubeConfigSet','New-KubeConfigSet','Set-KubeConfigSet','Remove-KubeConfigSet','Use-KubeConfigSet',
    'Get-KubeProfile','New-KubeProfile','Set-KubeProfile','Remove-KubeProfile','Use-KubeProfile',
    'Get-KubeSession','Clear-KubeSession','Invoke-KubeProfile','Invoke-KubeConfigSet','Set-KubeConfigEnvironment'
)
