# Internal implementation for KubeShell.Operations. Loaded into the parent module scope.

function Copy-ToKubePod {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory,ValueFromPipeline)] $Pod,
        [Parameter(Mandatory)] [string] $Destination,
        [string] $Namespace,
        [string] $Container
    )
    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $target = if ($identity.Namespace) { "$($identity.Namespace)/$($identity.Name):$Destination" } else { "$($identity.Name):$Destination" }
        if (-not $PSCmdlet.ShouldProcess($target, "Copy '$Path' into Kubernetes pod")) { return }
        Invoke-KubeRuntimeCopy -Pod $identity.Name -Namespace $identity.Namespace -LocalPath $Path -RemotePath $Destination -ToPod $true -Container $Container | Out-Null
    }
}
function Copy-FromKubePod {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,ValueFromPipeline)] $Pod,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination,
        [string] $Namespace,
        [string] $Container
    )
    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $source = if ($identity.Namespace) { "$($identity.Namespace)/$($identity.Name):$Path" } else { "$($identity.Name):$Path" }
        if (-not $PSCmdlet.ShouldProcess($Destination, "Copy '$source' from Kubernetes pod")) { return }
        Invoke-KubeRuntimeCopy -Pod $identity.Name -Namespace $identity.Namespace -LocalPath $Destination -RemotePath $Path -ToPod $false -Container $Container | Out-Null
    }
}
