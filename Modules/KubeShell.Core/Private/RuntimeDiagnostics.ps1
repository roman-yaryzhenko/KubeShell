# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Invoke-KubeRuntimeAccessReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Verb,
        [Parameter(Mandatory)] [string] $Resource,
        [string] $Name,
        [string] $Namespace,
        [string] $Group,
        [string] $Subresource,
        [bool] $Namespaced,
        [string] $As,
        [string[]] $AsGroup
    )
    try {
        $request = [KubeShell.Runtime.KubeAccessReviewRequest]::new(
            $Verb, $Resource, $Name, $Namespace, $Group, $Subresource, $Namespaced, $As, [string[]]@($AsGroup)
        )
        return (New-KubeRuntimeDiagnosticsClient).ReviewAccess((Get-KubeRuntimeTarget), $request, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject "$Verb $Resource")
    }
}

function Invoke-KubeRuntimePodMetrics {
    [CmdletBinding()]
    param([string] $Namespace)
    try {
        return (New-KubeRuntimeDiagnosticsClient).GetPodMetricsJson((Get-KubeRuntimeTarget), $Namespace, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject 'pod metrics')
    }
}

function Invoke-KubeRuntimeNodeMetrics {
    [CmdletBinding()]
    param()
    try {
        return (New-KubeRuntimeDiagnosticsClient).GetNodeMetricsJson((Get-KubeRuntimeTarget), (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject 'node metrics')
    }
}

function Invoke-KubeRuntimeDnsProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Image,
        [timespan] $Timeout = ([timespan]::FromSeconds(60))
    )
    try {
        $request = [KubeShell.Runtime.KubeDnsProbeRequest]::new($Namespace, $Name, $Image, $Timeout)
        return (New-KubeRuntimeDiagnosticsClient).ProbeDns((Get-KubeRuntimeTarget), $request, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Name)
    }
}
