# Internal implementation for KubeShell.Configuration. Loaded into the parent module scope.

function Get-KubeConfigSet {
    [CmdletBinding()]
    param([Parameter(Position=0)] [string] $Name)

    if ($Name) {
        $item = $script:ConfigSets[$Name]
        if ($item) { ConvertTo-KubeConfigSetObject $item }
        return
    }
    $script:ConfigSets.Values | Sort-Object Name | ForEach-Object { ConvertTo-KubeConfigSetObject $_ }
}
function New-KubeConfigSet {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [Parameter(Mandatory,Position=1)] [Alias('KubeConfig')] [string[]] $Path,
        [switch] $Force
    )

    if ($script:ConfigSets.ContainsKey($Name) -and -not $Force) {
        throw "Kubeconfig set '$Name' already exists. Use -Force to replace it."
    }
    $paths = @($Path | ForEach-Object { Resolve-KubeConfigPath $_ })
    if ($paths.Count -eq 0) { throw 'A kubeconfig set must contain at least one file.' }

    if ($PSCmdlet.ShouldProcess($Name,'Create kubeconfig set')) {
        $script:ConfigSets[$Name] = [KubeShell.Runtime.KubeConfigSet]::new($Name, [string[]]$paths)
        Save-KubeConfigurationStore
        ConvertTo-KubeConfigSetObject $script:ConfigSets[$Name]
    }
}
function Set-KubeConfigSet {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [Parameter(Mandatory)] [Alias('KubeConfig')] [string[]] $Path
    )

    if (-not $script:ConfigSets.ContainsKey($Name)) { throw "Kubeconfig set '$Name' does not exist." }
    $paths = @($Path | ForEach-Object { Resolve-KubeConfigPath $_ })
    if ($paths.Count -eq 0) { throw 'A kubeconfig set must contain at least one file.' }
    if ($PSCmdlet.ShouldProcess($Name,'Update kubeconfig set')) {
        $script:ConfigSets[$Name] = [KubeShell.Runtime.KubeConfigSet]::new($Name, [string[]]$paths)
        Save-KubeConfigurationStore
        $state = Get-KubeExecutionContext
        if ($state.ConfigSet -eq $Name) {
            Set-KubeExecutionContext -KubeConfigPaths $paths -Source ([string]$state.Source) | Out-Null
        }
        ConvertTo-KubeConfigSetObject $script:ConfigSets[$Name]
    }
}
function Remove-KubeConfigSet {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [switch] $Force
    )

    if (-not $script:ConfigSets.ContainsKey($Name)) { return }
    $dependentProfiles = @($script:Profiles.Values | Where-Object ConfigSet -EQ $Name)
    if ($dependentProfiles.Count -gt 0 -and -not $Force) {
        $names = ($dependentProfiles.Name | Sort-Object) -join ', '
        throw "Kubeconfig set '$Name' is referenced by profile(s): $names. Use -Force to remove those profiles too."
    }

    if ($PSCmdlet.ShouldProcess($Name,'Remove kubeconfig set')) {
        if ($Force) {
            foreach ($profile in $dependentProfiles) { [void]$script:Profiles.Remove([string]$profile.Name) }
        }
        [void]$script:ConfigSets.Remove($Name)
        Save-KubeConfigurationStore
        $state = Get-KubeExecutionContext
        if ($state.ConfigSet -eq $Name) { Initialize-KubeExecutionContext }
    }
}
function Use-KubeConfigSet {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline,ValueFromPipelineByPropertyName)] [string] $Name,
        [string] $Context,
        [string] $Namespace
    )

    process {
        $item = $script:ConfigSets[$Name]
        if (-not $item) { throw "Kubeconfig set '$Name' does not exist." }
        if ($PSCmdlet.ShouldProcess($Name,'Use kubeconfig set for this KubeShell session')) {
            Set-KubeExecutionContext -KubeConfigPaths @($item.Paths) -Context $Context -Namespace $Namespace -Profile $null -ConfigSet $Name -Source ConfigSet | Out-Null
            Get-KubeSession
        }
    }
}
