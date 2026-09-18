@{
    RootModule='KubeShell.Helm.psm1'
    ModuleVersion='0.3.0'
    GUID='3e792f45-23a7-48c8-8230-57dd81a2a934'
    Author='KubeShell contributors'
    Description='Optional Helm CLI extension for KubeShell.'
    PowerShellVersion='7.4'
    FunctionsToExport=@('Get-KubeHelmRelease','Get-KubeHelmValue','Get-KubeHelmHistory','Get-KubeHelmStatus')
    CmdletsToExport=@()
    AliasesToExport=@()
    VariablesToExport=@()
}
