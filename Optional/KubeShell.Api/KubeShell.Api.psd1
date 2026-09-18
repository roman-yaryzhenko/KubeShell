@{
    RootModule='KubeShell.Api.psm1'
    ModuleVersion='0.3.0'
    GUID='4f7d2bb5-bb89-43b8-906e-dcecc2dfa0b4'
    Author='KubeShell contributors'
    Description='Experimental managed Kubernetes API frontend for KubeShell using the official KubernetesClient backend.'
    PowerShellVersion='7.4'
    FunctionsToExport=@(
        'New-KubeApiSession','Get-KubeApiDiscovery','Get-KubeApiResource',
        'Set-KubeApiResourcePatch','Remove-KubeApiResource'
    )
    CmdletsToExport=@()
    AliasesToExport=@()
    VariablesToExport=@()
}
