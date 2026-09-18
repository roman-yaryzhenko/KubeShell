# Internal implementation for KubeShell.Operations. Loaded into the parent module scope.

function New-KubeWorkloadRuntimeIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Identity)

    $kind = [string]($Identity.Kind ?? 'Deployment')
    $resource = Resolve-KubeResourceName $kind
    return [KubeShell.Runtime.ResourceIdentity]::new($resource, $Identity.Name, $Identity.Namespace, $kind, $null)
}

function Restart-KubeDeployment {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Deployment,
        [string] $Namespace
    )

    process {
        $identity = Resolve-KubeIdentity $Deployment $Namespace 'Deployment'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/deployment/$($identity.Name)", 'Rollout restart')) { return }
        $result = Invoke-KubeRuntimeRolloutRestart -Identity (New-KubeWorkloadRuntimeIdentity $identity)
        if ($null -ne $result.Resource) { ConvertFrom-KubeRuntimeResource $result.Resource }
    }
}

function Set-KubeDeploymentScale {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Deployment,
        [Parameter(Mandatory)] [ValidateRange(0,1000000)] [int] $Replicas,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )

    process {
        $identity = Resolve-KubeIdentity $Deployment $Namespace 'Deployment'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/deployment/$($identity.Name)", "Scale to $Replicas replica(s)")) { return }
        $result = Invoke-KubeRuntimeScale -Identity (New-KubeWorkloadRuntimeIdentity $identity) -Replicas $Replicas -DryRun $DryRun
        if ($null -ne $result.Resource) { ConvertFrom-KubeRuntimeResource $result.Resource }
    }
}

function Wait-KubeRollout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Workload,
        [string] $Namespace,
        [timespan] $Timeout = [timespan]::FromMinutes(5)
    )

    process {
        $identity = Resolve-KubeIdentity $Workload $Namespace
        $result = Invoke-KubeRuntimeRolloutStatus -Identity (New-KubeWorkloadRuntimeIdentity $identity) -Timeout $Timeout
        if ($null -ne $result.Resource) { ConvertFrom-KubeRuntimeResource $result.Resource }
        foreach ($diagnostic in @($result.Diagnostics)) {
            if ($diagnostic.Code -eq 'rollout.status') { Write-Verbose $diagnostic.Message }
        }
    }
}

function Undo-KubeRollout {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Workload,
        [string] $Namespace,
        [ValidateRange(1,[int]::MaxValue)] [int] $ToRevision
    )

    process {
        $identity = Resolve-KubeIdentity $Workload $Namespace
        $runtimeIdentity = New-KubeWorkloadRuntimeIdentity $identity
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/$($runtimeIdentity.Resource)/$($identity.Name)", 'Undo rollout')) { return }

        $result = Invoke-KubeRuntimeRolloutUndo -Identity $runtimeIdentity -ToRevision $(if ($ToRevision) { [long]$ToRevision } else { 0L })
        if ($null -ne $result.Resource) {
            ConvertFrom-KubeRuntimeResource $result.Resource
        }
        else {
            [pscustomobject]@{
                PSTypeName  = 'KubeShell.RolloutUndoResult'
                Resource    = $runtimeIdentity.Resource
                Name        = $identity.Name
                Namespace   = $identity.Namespace
                Revision    = if ($ToRevision) { $ToRevision } else { $null }
                Diagnostics = @($result.Diagnostics)
            }
        }
    }
}

function Set-KubeImage {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Workload,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $Image,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )

    process {
        $identity = Resolve-KubeIdentity $Workload $Namespace
        $runtimeIdentity = New-KubeWorkloadRuntimeIdentity $identity
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/$($runtimeIdentity.Resource)/$($identity.Name)", "Set image $Container=$Image")) { return }
        $result = Invoke-KubeRuntimeSetImage -Identity $runtimeIdentity -Container $Container -Image $Image -DryRun $DryRun
        if ($null -ne $result.Resource) { ConvertFrom-KubeRuntimeResource $result.Resource }
    }
}
