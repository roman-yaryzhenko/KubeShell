# Internal implementation for KubeShell.Configuration. Loaded into the parent module scope.

function Get-KubeProfile {
    [CmdletBinding()]
    param([Parameter(Position=0)] [string] $Name)

    if ($Name) {
        $item = $script:Profiles[$Name]
        if ($item) { ConvertTo-KubeProfileObject $item }
        return
    }
    $script:Profiles.Values | Sort-Object Name | ForEach-Object { ConvertTo-KubeProfileObject $_ }
}
function New-KubeProfile {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [Parameter(Mandatory)] [string] $ConfigSet,
        [string] $Context,
        [string] $Namespace,
        [switch] $Force
    )

    if (-not $script:ConfigSets.ContainsKey($ConfigSet)) { throw "Kubeconfig set '$ConfigSet' does not exist." }
    if ($script:Profiles.ContainsKey($Name) -and -not $Force) { throw "Kubernetes profile '$Name' already exists. Use -Force to replace it." }

    if ($PSCmdlet.ShouldProcess($Name,'Create Kubernetes profile')) {
        $script:Profiles[$Name] = [KubeShell.Runtime.KubeProfile]::new($Name, $ConfigSet, $Context, $Namespace)
        Save-KubeConfigurationStore
        ConvertTo-KubeProfileObject $script:Profiles[$Name]
    }
}
function Set-KubeProfile {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [string] $ConfigSet,
        [AllowNull()] [string] $Context,
        [AllowNull()] [string] $Namespace
    )

    $item = $script:Profiles[$Name]
    if (-not $item) { throw "Kubernetes profile '$Name' does not exist." }
    if ($ConfigSet -and -not $script:ConfigSets.ContainsKey($ConfigSet)) { throw "Kubeconfig set '$ConfigSet' does not exist." }

    if ($PSCmdlet.ShouldProcess($Name,'Update Kubernetes profile')) {
        $nextConfigSet = if ($PSBoundParameters.ContainsKey('ConfigSet')) { $ConfigSet } else { [string]$item.ConfigSet }
        $nextContext = if ($PSBoundParameters.ContainsKey('Context')) { $Context } else { $item.Context }
        $nextNamespace = if ($PSBoundParameters.ContainsKey('Namespace')) { $Namespace } else { $item.Namespace }
        $script:Profiles[$Name] = [KubeShell.Runtime.KubeProfile]::new($Name, $nextConfigSet, $nextContext, $nextNamespace)
        Save-KubeConfigurationStore
        if ((Get-KubeExecutionContext).Profile -eq $Name) { Use-KubeProfile $Name -Confirm:$false | Out-Null }
        ConvertTo-KubeProfileObject $script:Profiles[$Name]
    }
}
function Remove-KubeProfile {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param([Parameter(Mandatory,Position=0)] [string] $Name)

    if (-not $script:Profiles.ContainsKey($Name)) { return }
    if ($PSCmdlet.ShouldProcess($Name,'Remove Kubernetes profile')) {
        [void]$script:Profiles.Remove($Name)
        Save-KubeConfigurationStore
        if ((Get-KubeExecutionContext).Profile -eq $Name) { Initialize-KubeExecutionContext }
    }
}
function Use-KubeProfile {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param([Parameter(Mandatory,Position=0,ValueFromPipeline,ValueFromPipelineByPropertyName)] [string] $Name)

    process {
        $profile = $script:Profiles[$Name]
        if (-not $profile) { throw "Kubernetes profile '$Name' does not exist." }
        $configSet = $script:ConfigSets[[string]$profile.ConfigSet]
        if (-not $configSet) { throw "Kubeconfig set '$($profile.ConfigSet)' referenced by profile '$Name' does not exist." }

        if ($PSCmdlet.ShouldProcess($Name,'Use Kubernetes profile for this KubeShell session')) {
            Set-KubeExecutionContext -KubeConfigPaths @($configSet.Paths) -Context $profile.Context -Namespace $profile.Namespace -Profile $Name -ConfigSet $profile.ConfigSet -Source Profile | Out-Null
            Get-KubeSession
        }
    }
}
