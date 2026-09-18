# Internal implementation for KubeShell.Shell. Loaded into the parent module scope.

function Get-KubeContext {
    [CmdletBinding()]
    param()

    $config = Get-KubeRuntimeConfigView
    $state = Get-KubeExecutionContext
    $current = if ([string]::IsNullOrEmpty([string]$state.Context)) {
        [string]$config.CurrentContext
    }
    else {
        [string]$state.Context
    }

    foreach ($context in @($config.Contexts)) {
        if ($null -eq $context) { continue }
        $name = [string]$context.Name
        $namespace = [string]$context.Namespace
        if ($name -ceq $current -and -not [string]::IsNullOrWhiteSpace([string]$state.Namespace)) {
            $namespace = [string]$state.Namespace
        }
        if ([string]::IsNullOrWhiteSpace($namespace)) { $namespace = 'default' }

        [pscustomobject]@{
            PSTypeName = 'KubeShell.Context'
            Name       = $name
            Current    = $name -ceq $current
            Cluster    = [string]$context.Cluster
            User       = [string]$context.User
            Namespace  = $namespace
        }
    }
}
function Set-KubeContext {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param([Parameter(Mandatory,Position=0,ValueFromPipeline,ValueFromPipelineByPropertyName)][Alias('Context')][string]$Name)
    process {
        $known = @(Get-KubeContext | Where-Object Name -CEQ $Name)
        if ($known.Count -eq 0) { throw "Kubernetes context '$Name' does not exist in the active kubeconfig set." }
        if ($PSCmdlet.ShouldProcess($Name,'Switch KubeShell session context')) {
            # Session-local context avoids rewriting current-context in a user's kubeconfig file.
            Set-KubeExecutionContext -Context $Name -Profile $null -Source Explicit | Out-Null
            Get-KubeContext | Where-Object Current
        }
    }
}
function Get-KubeCurrentNamespace {
    [CmdletBinding()]
    param()
    $context = Get-KubeContext | Where-Object Current | Select-Object -First 1
    if ($context) { return $context.Namespace }
    return 'default'
}
function Set-KubeNamespace {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param([Parameter(Mandatory,Position=0)][string]$Name)
    if ($PSCmdlet.ShouldProcess($Name,'Set KubeShell session namespace')) {
        # Keep namespace as a transport override rather than mutating the selected context on disk.
        Set-KubeExecutionContext -Namespace $Name -Profile $null -Source Explicit | Out-Null
        Get-KubeContext | Where-Object Current
    }
}
function Push-KubeContext {
    [CmdletBinding()]
    param([string]$Context,[string]$Namespace)

    $script:ContextStack.Push((Get-KubeExecutionContext))
    if ($Context) { Set-KubeContext $Context -Confirm:$false | Out-Null }
    if ($Namespace) { Set-KubeNamespace $Namespace -Confirm:$false | Out-Null }
    Get-KubeContext | Where-Object Current
}
function Pop-KubeContext {
    [CmdletBinding()]
    param()
    if ($script:ContextStack.Count -eq 0) { throw 'Kubernetes context stack is empty.' }
    $previous = $script:ContextStack.Pop()
    Restore-KubeExecutionContext $previous
    Get-KubeContext | Where-Object Current
}
