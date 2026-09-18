# Internal implementation for KubeShell.Operations. Loaded into the parent module scope.

function Remove-KubeResource {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $InputObject,
        [string] $Resource,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None',
        [switch] $Force,
        [timespan] $GracePeriod,
        [string] $ApiVersion
    )

    process {
        $identity = Resolve-KubeIdentity $InputObject $Namespace
        $resourceName = if ($Resource) { $Resource } elseif ($identity.Kind) { Resolve-KubeResourceName $identity.Kind } else { throw 'Resource is required for string input.' }
        $target = "$resourceName/$($identity.Name)"
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/$target", 'Delete Kubernetes resource')) { return }

        $graceSeconds = if ($Force) {
            0
        }
        elseif ($PSBoundParameters.ContainsKey('GracePeriod') -and $GracePeriod -ge [timespan]::Zero) {
            [int][math]::Floor($GracePeriod.TotalSeconds)
        }
        else {
            $null
        }

        $runtimeIdentity = [KubeShell.Runtime.ResourceIdentity]::new(
            $resourceName,
            [string]$identity.Name,
            [string]$identity.Namespace,
            [string]$identity.Kind,
            $ApiVersion
        )
        $options = [KubeShell.Runtime.KubeDeleteOptions]::new(
            (ConvertTo-KubeRuntimeDryRunMode $DryRun),
            [bool]$Force,
            $graceSeconds
        )
        Invoke-KubeRuntimeDelete -Identity $runtimeIdentity -Options $options
        New-KubeChangeResult -Operation Delete -Identity $runtimeIdentity -DryRun $DryRun
    }
}
function Remove-KubePod {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Pod,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None',
        [switch] $Force
    )
    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/pod/$($identity.Name)", 'Delete Kubernetes pod')) { return }
        Remove-KubeResource -InputObject $Pod -Resource pod -Namespace $Namespace -DryRun $DryRun -Force:$Force -Confirm:$false
    }
}
function Set-KubeCronJobSuspension {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $CronJob,
        [Parameter(Mandatory)] [bool] $Suspend,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None'
    )
    process {
        $identity = Resolve-KubeIdentity $CronJob $Namespace 'CronJob'
        $action = if ($Suspend) { 'Suspend CronJob' } else { 'Resume CronJob' }
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/cronjob/$($identity.Name)", $action)) { return }

        $patch = @{ spec = @{ suspend = $Suspend } } | ConvertTo-Json -Compress
        $runtimeIdentity = [KubeShell.Runtime.ResourceIdentity]::new(
            'cronjob',
            [string]$identity.Name,
            [string]$identity.Namespace,
            'CronJob',
            'batch/v1'
        )
        $options = [KubeShell.Runtime.KubePatchOptions]::new(
            [KubeShell.Runtime.KubePatchType]::Merge,
            (ConvertTo-KubeRuntimeDryRunMode $DryRun)
        )
        $runtimeResource = Invoke-KubeRuntimePatch -Identity $runtimeIdentity -PayloadJson $patch -Options $options
        ConvertFrom-KubeRuntimeResource $runtimeResource
    }
}
function Suspend-KubeCronJob {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param([Parameter(Mandatory,ValueFromPipeline)]$CronJob,[string]$Namespace,[ValidateSet('None','Client','Server')][string]$DryRun='None')
    process {
        $identity = Resolve-KubeIdentity $CronJob $Namespace 'CronJob'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/cronjob/$($identity.Name)", 'Suspend CronJob')) { return }
        Set-KubeCronJobSuspension -CronJob $CronJob -Namespace $Namespace -Suspend $true -DryRun $DryRun -Confirm:$false
    }
}
function Resume-KubeCronJob {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param([Parameter(Mandatory,ValueFromPipeline)]$CronJob,[string]$Namespace,[ValidateSet('None','Client','Server')][string]$DryRun='None')
    process {
        $identity = Resolve-KubeIdentity $CronJob $Namespace 'CronJob'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/cronjob/$($identity.Name)", 'Resume CronJob')) { return }
        Set-KubeCronJobSuspension -CronJob $CronJob -Namespace $Namespace -Suspend $false -DryRun $DryRun -Confirm:$false
    }
}
