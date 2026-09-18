Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../Modules/KubeShell.Core/KubeShell.Core.psd1') -Scope Local
Import-Module (Join-Path $PSScriptRoot '../../Modules/KubeShell.Resources/KubeShell.Resources.psd1') -Scope Local
Import-Module (Join-Path $PSScriptRoot '../../Modules/KubeShell.Manifests/KubeShell.Manifests.psd1') -Scope Local

function Get-KubeFluxKustomization {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces
    )

    $parameters = @{ Resource='kustomizations.kustomize.toolkit.fluxcd.io' }
    if ($Name) { $parameters.Name = $Name }
    if ($Namespace) { $parameters.Namespace = $Namespace }
    if ($AllNamespaces) { $parameters.AllNamespaces = $true }
    Get-KubeResource @parameters
}

function Get-KubeFluxHelmRelease {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces
    )

    $parameters = @{ Resource='helmreleases.helm.toolkit.fluxcd.io' }
    if ($Name) { $parameters.Name = $Name }
    if ($Namespace) { $parameters.Namespace = $Namespace }
    if ($AllNamespaces) { $parameters.AllNamespaces = $true }
    Get-KubeResource @parameters
}

function Get-KubeFluxGitRepository {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces
    )

    $parameters = @{ Resource='gitrepositories.source.toolkit.fluxcd.io' }
    if ($Name) { $parameters.Name = $Name }
    if ($Namespace) { $parameters.Namespace = $Namespace }
    if ($AllNamespaces) { $parameters.AllNamespaces = $true }
    Get-KubeResource @parameters
}

function Request-KubeFluxReconcile {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline)] $InputObject,
        [Parameter(Mandatory)] [string] $Resource,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None'
    )

    process {
        $identity = Resolve-KubeIdentity $InputObject $Namespace
        $target = "$Resource/$($identity.Name)"
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/$target",'Request Flux reconciliation')) { return }

        # Flux reconciles when requestedAt differs from the last handled value. Milliseconds
        # make repeated interactive requests unique without storing additional client state.
        $requestedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString([Globalization.CultureInfo]::InvariantCulture)
        $patch = @{
            metadata = @{
                annotations = @{
                    'reconcile.fluxcd.io/requestedAt' = $requestedAt
                }
            }
        }

        Set-KubeResourcePatch -Resource $Resource -Name $identity.Name -Namespace $identity.Namespace -Patch $patch -Type Merge -DryRun $DryRun -Confirm:$false
    }
}

function Sync-KubeFluxKustomization {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline)] $Kustomization,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None'
    )
    process {
        $identity = Resolve-KubeIdentity $Kustomization $Namespace 'Kustomization'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/kustomization/$($identity.Name)",'Request Flux Kustomization reconciliation')) { return }
        Request-KubeFluxReconcile -InputObject $Kustomization -Resource 'kustomization' -Namespace $Namespace -DryRun $DryRun -Confirm:$false
    }
}

function Sync-KubeFluxHelmRelease {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline)] $HelmRelease,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None'
    )
    process {
        $identity = Resolve-KubeIdentity $HelmRelease $Namespace 'HelmRelease'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/helmrelease/$($identity.Name)",'Request Flux HelmRelease reconciliation')) { return }
        Request-KubeFluxReconcile -InputObject $HelmRelease -Resource 'helmrelease' -Namespace $Namespace -DryRun $DryRun -Confirm:$false
    }
}

function Set-KubeFluxSuspension {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory,ValueFromPipeline)] $InputObject,
        [Parameter(Mandatory)] [string] $Resource,
        [Parameter(Mandatory)] [bool] $Suspend,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None'
    )

    process {
        $identity = Resolve-KubeIdentity $InputObject $Namespace
        $verb = if ($Suspend) { 'Suspend Flux reconciliation' } else { 'Resume Flux reconciliation' }
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/$Resource/$($identity.Name)",$verb)) { return }

        Set-KubeResourcePatch -Resource $Resource -Name $identity.Name -Namespace $identity.Namespace `
            -Patch @{ spec=@{ suspend=$Suspend } } -Type Merge -DryRun $DryRun -Confirm:$false
    }
}

function Suspend-KubeFluxKustomization {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory,ValueFromPipeline)]$Kustomization,[string]$Namespace,[ValidateSet('None','Client','Server')][string]$DryRun='None')
    process {
        $identity = Resolve-KubeIdentity $Kustomization $Namespace 'Kustomization'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/kustomization/$($identity.Name)",'Suspend Flux Kustomization')) { return }
        Set-KubeFluxSuspension -InputObject $Kustomization -Resource 'kustomization' -Suspend $true -Namespace $Namespace -DryRun $DryRun -Confirm:$false
    }
}

function Resume-KubeFluxKustomization {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory,ValueFromPipeline)]$Kustomization,[string]$Namespace,[ValidateSet('None','Client','Server')][string]$DryRun='None')
    process {
        $identity = Resolve-KubeIdentity $Kustomization $Namespace 'Kustomization'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/kustomization/$($identity.Name)",'Resume Flux Kustomization')) { return }
        Set-KubeFluxSuspension -InputObject $Kustomization -Resource 'kustomization' -Suspend $false -Namespace $Namespace -DryRun $DryRun -Confirm:$false
    }
}

function Suspend-KubeFluxHelmRelease {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory,ValueFromPipeline)]$HelmRelease,[string]$Namespace,[ValidateSet('None','Client','Server')][string]$DryRun='None')
    process {
        $identity = Resolve-KubeIdentity $HelmRelease $Namespace 'HelmRelease'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/helmrelease/$($identity.Name)",'Suspend Flux HelmRelease')) { return }
        Set-KubeFluxSuspension -InputObject $HelmRelease -Resource 'helmrelease' -Suspend $true -Namespace $Namespace -DryRun $DryRun -Confirm:$false
    }
}

function Resume-KubeFluxHelmRelease {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory,ValueFromPipeline)]$HelmRelease,[string]$Namespace,[ValidateSet('None','Client','Server')][string]$DryRun='None')
    process {
        $identity = Resolve-KubeIdentity $HelmRelease $Namespace 'HelmRelease'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/helmrelease/$($identity.Name)",'Resume Flux HelmRelease')) { return }
        Set-KubeFluxSuspension -InputObject $HelmRelease -Resource 'helmrelease' -Suspend $false -Namespace $Namespace -DryRun $DryRun -Confirm:$false
    }
}

Export-ModuleMember -Function @(
    'Get-KubeFluxKustomization','Get-KubeFluxHelmRelease','Get-KubeFluxGitRepository',
    'Sync-KubeFluxKustomization','Sync-KubeFluxHelmRelease',
    'Suspend-KubeFluxKustomization','Resume-KubeFluxKustomization',
    'Suspend-KubeFluxHelmRelease','Resume-KubeFluxHelmRelease'
)
