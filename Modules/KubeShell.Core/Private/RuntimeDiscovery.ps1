# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Get-KubeRuntimeConfigView {
    [CmdletBinding()]
    param()
    try {
        return (New-KubeRuntimeConfigClient).GetConfigView((Get-KubeRuntimeTarget))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject 'kubeconfig')
    }
}

function Invoke-KubeRuntimePreferredResources {
    [CmdletBinding()]
    param([switch] $Refresh)

    try {
        $client = New-KubeRuntimeDiscoveryClient
        return $client.GetPreferredResources((Get-KubeRuntimeTarget), (Get-KubeRuntimeExecutionContext), [bool]$Refresh)
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject 'discovery')
    }
}

function Invoke-KubeRuntimeResolveResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [string] $ApiVersion,
        [switch] $Refresh
    )

    try {
        $client = New-KubeRuntimeDiscoveryClient
        $gvr = [KubeShell.Runtime.GroupVersionResource]::FromLegacy($Resource, $ApiVersion)
        return $client.ResolveResource((Get-KubeRuntimeTarget), $gvr, (Get-KubeRuntimeExecutionContext), [bool]$Refresh)
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Resource)
    }
}

function Invoke-KubeRuntimeSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [string] $Field,
        [string] $ApiVersion,
        [switch] $Recursive,
        [ValidateRange(0,64)] [int] $MaxDepth = 0
    )

    try {
        $client = New-KubeRuntimeSchemaClient
        $request = [KubeShell.Runtime.KubeSchemaRequest]::new(
            [KubeShell.Runtime.GroupVersionResource]::FromLegacy($Resource, $ApiVersion),
            $Field,
            [bool]$Recursive,
            $MaxDepth
        )
        return $client.GetSchema((Get-KubeRuntimeTarget), $request, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Resource)
    }
}
