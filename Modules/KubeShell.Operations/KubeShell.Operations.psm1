Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Core/KubeShell.Core.psd1') -Scope Local
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Resources/KubeShell.Resources.psd1') -Scope Local

# Mutation and interactive operations stay in one public module, but are split by operational concern.
$privateScripts = @(
    'LogsExec.ps1'
    'Workloads.ps1'
    'Mutations.ps1'
    'Debug.ps1'
    'PortForward.ps1'
    'Copy.ps1'
)
foreach ($privateScript in $privateScripts) {
    . (Join-Path $PSScriptRoot "Private/$privateScript")
}

Export-ModuleMember -Function @(
    'Get-KubeLog','Invoke-KubeExec','Enter-KubePod','Restart-KubeDeployment','Set-KubeDeploymentScale','Wait-KubeRollout','Undo-KubeRollout',
    'Set-KubeImage','Remove-KubeResource','Remove-KubePod','Suspend-KubeCronJob','Resume-KubeCronJob','Enter-KubeDebugPod','Enter-KubeNode',
    'Start-KubePortForward','Stop-KubePortForward','Copy-ToKubePod','Copy-FromKubePod'
)
