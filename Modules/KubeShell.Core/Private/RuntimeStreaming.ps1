# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Invoke-KubeRuntimeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Pod,
        [string] $Namespace,
        [string] $Container,
        [long] $Tail = 200,
        [timespan] $Since,
        [switch] $Previous,
        [switch] $Follow,
        [switch] $Timestamps,
        [switch] $Prefix
    )
    try {
        $scope = if ([string]::IsNullOrWhiteSpace($Namespace)) {
            [KubeShell.Runtime.KubeNamespaceScope]::Default
        }
        else {
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit($Namespace)
        }
        $sinceValue = if ($PSBoundParameters.ContainsKey('Since')) { $Since } else { $null }
        $request = [KubeShell.Runtime.KubeLogRequest]::new(
            $Pod, $scope, $Container, $Tail, $sinceValue, [bool]$Previous, [bool]$Follow, [bool]$Timestamps, [bool]$Prefix
        )
        foreach ($line in (New-KubeRuntimeLogClient).ReadLogs((Get-KubeRuntimeTarget), $request, (Get-KubeRuntimeExecutionContext))) { $line }
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Pod)
    }
}

function Invoke-KubeRuntimeCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Pod,
        [string] $Namespace,
        [Parameter(Mandatory)] [string] $LocalPath,
        [Parameter(Mandatory)] [string] $RemotePath,
        [Parameter(Mandatory)] [bool] $ToPod,
        [string] $Container
    )
    try {
        $scope = if ([string]::IsNullOrWhiteSpace($Namespace)) {
            [KubeShell.Runtime.KubeNamespaceScope]::Default
        }
        else {
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit($Namespace)
        }
        $request = [KubeShell.Runtime.KubeCopyRequest]::new($Pod, $scope, $LocalPath, $RemotePath, $ToPod, $Container)
        return (New-KubeRuntimeCopyClient).Copy((Get-KubeRuntimeTarget), $request, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Pod)
    }
}

function Invoke-KubeRuntimeDebugRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [KubeShell.Runtime.KubeDebugRequest] $Request)

    try {
        return (New-KubeRuntimeDebugClient).Debug((Get-KubeRuntimeTarget), $Request, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Request.Target)
    }
}

function Invoke-KubeRuntimeDebug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Target,
        [Parameter(Mandatory)] [string] $Image,
        [string[]] $Command = @(),
        [string] $TargetContainer,
        [string] $Profile = 'general'
    )

    $request = [KubeShell.Runtime.KubeDebugRequest]::new(
        $Target, $Image, [string[]]@($Command), $TargetContainer, $Profile
    )
    return Invoke-KubeRuntimeDebugRequest -Request $request
}
