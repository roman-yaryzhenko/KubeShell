# Internal implementation for KubeShell.Configuration. Loaded into the parent module scope.

function Initialize-KubeExecutionContext {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrEmpty($env:KUBECONFIG)) {
        $paths = @($env:KUBECONFIG -split [regex]::Escape([string][IO.Path]::PathSeparator) | Where-Object { $null -ne $_ -and $_.Length -gt 0 })
        Set-KubeExecutionContext -KubeConfigPaths $paths -Context $null -Namespace $null -Profile $null -ConfigSet $null -Source Environment | Out-Null
        return
    }

    $home = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($home)) { $home = $HOME }
    if ([string]::IsNullOrWhiteSpace([string]$home)) {
        throw 'Cannot resolve the current user home directory for the default Kubernetes config.'
    }
    # The native backend never consults ambient process state. Resolve the conventional default
    # here so KubeTarget remains explicit even when KUBECONFIG is not set.
    $defaultKubeConfig = Join-Path (Join-Path $home '.kube') 'config'
    Set-KubeExecutionContext -KubeConfigPaths @($defaultKubeConfig) -Context $null -Namespace $null -Profile $null -ConfigSet $null -Source Default | Out-Null
}
function Get-KubeSession {
    [CmdletBinding()]
    param()

    $state = Get-KubeExecutionContext
    $effectiveContext = $state.Context
    $effectiveNamespace = $state.Namespace
    $configError = $null

    try {
        $config = Get-KubeRuntimeConfigView
        if ([string]::IsNullOrEmpty([string]$effectiveContext)) {
            $effectiveContext = [string]$config.CurrentContext
        }
        if ([string]::IsNullOrWhiteSpace([string]$effectiveNamespace) -and -not [string]::IsNullOrEmpty([string]$effectiveContext)) {
            $selected = @($config.Contexts | Where-Object { [string]$_.Name -ceq [string]$effectiveContext } | Select-Object -First 1)
            if ($selected.Count -gt 0) { $effectiveNamespace = [string]$selected[0].Namespace }
        }
    }
    catch {
        $configError = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace([string]$effectiveNamespace)) { $effectiveNamespace = 'default' }

    [pscustomobject]@{
        PSTypeName       = 'KubeShell.Session'
        Profile          = $state.Profile
        ConfigSet        = $state.ConfigSet
        KubeConfigPaths  = @($state.KubeConfigPaths)
        Context          = $effectiveContext
        Namespace        = $effectiveNamespace
        Source           = $state.Source
        ConfigurationStore = Get-KubeConfigurationStorePath
        ConfigReadable   = $null -eq $configError
        ConfigError      = $configError
    }
}
function Clear-KubeSession {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param()

    if ($PSCmdlet.ShouldProcess('KubeShell session','Return to KUBECONFIG/default kubeconfig resolution')) {
        Initialize-KubeExecutionContext
        Get-KubeSession
    }
}
function Invoke-KubeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [Parameter(Mandatory,Position=1)] [scriptblock] $ScriptBlock
    )

    $previous = Get-KubeExecutionContext
    try {
        Use-KubeProfile $Name -Confirm:$false | Out-Null
        & $ScriptBlock
    }
    finally {
        Restore-KubeExecutionContext $previous
    }
}
function Invoke-KubeConfigSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [Parameter(Mandatory,Position=1)] [scriptblock] $ScriptBlock,
        [string] $Context,
        [string] $Namespace
    )

    $previous = Get-KubeExecutionContext
    try {
        Use-KubeConfigSet $Name -Context $Context -Namespace $Namespace -Confirm:$false | Out-Null
        & $ScriptBlock
    }
    finally {
        Restore-KubeExecutionContext $previous
    }
}
function Set-KubeConfigEnvironment {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([switch] $PassThru)

    $paths = @((Get-KubeExecutionContext).KubeConfigPaths)
    $separator = [IO.Path]::PathSeparator
    if (@($paths | Where-Object { $_.Contains([string]$separator) }).Count -gt 0) {
        throw "The selected kubeconfig set contains a path with '$separator' and cannot be represented losslessly in KUBECONFIG."
    }
    $value = if ($paths.Count -gt 0) { $paths -join $separator } else { $null }
    $target = if ($null -eq $value) { 'remove KUBECONFIG' } else { "KUBECONFIG=$value" }

    if ($PSCmdlet.ShouldProcess('current PowerShell process',$target)) {
        $env:KUBECONFIG = $value
        if ($PassThru) { return $value }
    }
}
