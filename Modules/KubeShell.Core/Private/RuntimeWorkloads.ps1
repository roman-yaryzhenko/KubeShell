# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Invoke-KubeRuntimeRolloutUndo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [ValidateRange(0,[long]::MaxValue)] [long] $ToRevision = 0,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )

    try {
        $operation = [KubeShell.Runtime.KubeRolloutUndoOperation]::new(
            $Identity,
            $ToRevision,
            [KubeShell.Runtime.KubePreviewMode]([Enum]::Parse([KubeShell.Runtime.KubePreviewMode], $DryRun, $true))
        )
        return (Get-KubeRuntimeOperationClient).Execute((Get-KubeRuntimeTarget), $operation, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimeRolloutRestart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )
    try {
        $operation = [KubeShell.Runtime.KubeRolloutRestartOperation]::new(
            $Identity,
            [KubeShell.Runtime.KubePreviewMode]([Enum]::Parse([KubeShell.Runtime.KubePreviewMode], $DryRun, $true)),
            'kubeshell-rollout'
        )
        return (Get-KubeRuntimeOperationClient).Execute((Get-KubeRuntimeTarget), $operation, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimeScale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [int] $Replicas,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )
    try {
        $operation = [KubeShell.Runtime.KubeScaleOperation]::new(
            $Identity,
            $Replicas,
            [KubeShell.Runtime.KubePreviewMode]([Enum]::Parse([KubeShell.Runtime.KubePreviewMode], $DryRun, $true))
        )
        return (Get-KubeRuntimeOperationClient).Execute((Get-KubeRuntimeTarget), $operation, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimeSetImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $Image,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )
    try {
        $operation = [KubeShell.Runtime.KubeSetImageOperation]::new(
            $Identity,
            $Container,
            $Image,
            [KubeShell.Runtime.KubePreviewMode]([Enum]::Parse([KubeShell.Runtime.KubePreviewMode], $DryRun, $true)),
            'kubeshell-set-image'
        )
        return (Get-KubeRuntimeOperationClient).Execute((Get-KubeRuntimeTarget), $operation, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimeRolloutStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [timespan] $Timeout,
        [ValidateRange(0,[long]::MaxValue)] [long] $Revision = 0
    )
    try {
        $operation = [KubeShell.Runtime.KubeRolloutStatusOperation]::new($Identity, $Timeout, $Revision)
        return (Get-KubeRuntimeOperationClient).Execute((Get-KubeRuntimeTarget), $operation, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}
