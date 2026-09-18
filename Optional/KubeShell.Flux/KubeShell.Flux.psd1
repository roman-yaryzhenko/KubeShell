@{
    RootModule='KubeShell.Flux.psm1'
    ModuleVersion='0.3.0'
    GUID='0ed6d3c0-75ac-4a8f-81b6-f952570845e4'
    Author='KubeShell contributors'
    Description='Optional Flux extension for KubeShell.'
    PowerShellVersion='7.4'
    FunctionsToExport=@(
        'Get-KubeFluxKustomization','Get-KubeFluxHelmRelease','Get-KubeFluxGitRepository',
        'Sync-KubeFluxKustomization','Sync-KubeFluxHelmRelease',
        'Suspend-KubeFluxKustomization','Resume-KubeFluxKustomization',
        'Suspend-KubeFluxHelmRelease','Resume-KubeFluxHelmRelease'
    )
    CmdletsToExport=@()
    AliasesToExport=@()
    VariablesToExport=@()
}
