Set-StrictMode -Version Latest

$moduleOrder = @('Core','Configuration','Resources','Operations','Manifests','Diagnostics','Shell')
foreach ($name in $moduleOrder) {
    $modulePath = Join-Path $PSScriptRoot "Modules/KubeShell.$name/KubeShell.$name.psd1"
    Import-Module $modulePath -Scope Local -Force
}

# Aliases keep the terse kubectl-like muscle memory while the public functions use
# PowerShell-approved verbs and predictable noun names.
Set-Alias -Name kgp  -Value Get-KubePod
Set-Alias -Name kgd  -Value Get-KubeDeployment
Set-Alias -Name kgs  -Value Get-KubeService
Set-Alias -Name kgn  -Value Get-KubeNode
Set-Alias -Name kge  -Value Get-KubeEvent
Set-Alias -Name klog -Value Get-KubeLog
Set-Alias -Name kx   -Value Invoke-KubeExec
Set-Alias -Name kwatch -Value Watch-KubeResource

# Completion registration is cheap at import time; API calls happen only when TAB is requested.
Enable-KubeCompletion

$publicFunctions = @(
    'Get-KubeResource','Get-KubePod','Get-KubeDeployment','Get-KubeStatefulSet','Get-KubeDaemonSet','Get-KubeReplicaSet',
    'Get-KubeJob','Get-KubeCronJob','Get-KubeService','Get-KubeIngress','Get-KubeConfigMap','Get-KubeSecret','Get-KubeSecretValue',
    'Get-KubeNode','Get-KubeNamespace','Get-KubePersistentVolumeClaim','Get-KubePersistentVolume','Get-KubeStorageClass','Get-KubeEndpointSlice',
    'Get-KubeRole','Get-KubeRoleBinding','Get-KubeClusterRole','Get-KubeClusterRoleBinding','Get-KubeEvent','Get-KubeContainer','Get-KubeKind','Get-KubeSchema','Get-KubeSchemaField','Watch-KubeResource',
    'Get-KubeLog','Invoke-KubeExec','Enter-KubePod','Restart-KubeDeployment','Set-KubeDeploymentScale','Wait-KubeRollout','Undo-KubeRollout',
    'Set-KubeImage','Remove-KubeResource','Remove-KubePod','Suspend-KubeCronJob','Resume-KubeCronJob','Enter-KubeDebugPod','Enter-KubeNode',
    'Start-KubePortForward','Stop-KubePortForward','Copy-ToKubePod','Copy-FromKubePod',
    'Set-KubeManifest','Test-KubeManifest','Compare-KubeManifest','Remove-KubeManifest','Set-KubeResourcePatch','Set-KubeObject',
    'Get-KubeYaml','Get-KubeJson','ConvertFrom-KubeYaml','ConvertTo-KubeYaml',
    'Get-KubeCondition','Get-KubeOwner','Get-KubeDependent','Get-KubeEventsFor','Test-KubePod','Test-KubeDeployment','Test-KubeCluster',
    'Test-KubeAccess','Get-KubeTopPod','Get-KubeTopNode','Get-KubeNodeAllocation','Get-KubeOvercommit','Resolve-KubeService','Test-KubeService','Test-KubeDns',
    'Get-KubeConfigurationStorePath','Get-KubeConfigSet','New-KubeConfigSet','Set-KubeConfigSet','Remove-KubeConfigSet','Use-KubeConfigSet',
    'Get-KubeProfile','New-KubeProfile','Set-KubeProfile','Remove-KubeProfile','Use-KubeProfile','Get-KubeSession','Clear-KubeSession',
    'Invoke-KubeProfile','Invoke-KubeConfigSet','Set-KubeConfigEnvironment',
    'Get-KubeContext','Set-KubeContext','Get-KubeCurrentNamespace','Set-KubeNamespace','Push-KubeContext','Pop-KubeContext',
    'Get-KubePromptSegment','Enable-KubePrompt','Disable-KubePrompt','Set-KubeBookmark','Get-KubeBookmark','Remove-KubeBookmark','Use-KubeBookmark',
    'Select-KubeResource','Invoke-Kubectl','Enable-KubeCompletion'
)

Export-ModuleMember -Function $publicFunctions -Alias @(
    'kgp','kgd','kgs','kgn','kge','klog','kx','kwatch'
)
