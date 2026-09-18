# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Get-KubeExecutionContextStore {
    [CmdletBinding()]
    param()

    # Nested modules can reload Core in separate module scopes. Keep one state per PowerShell
    # runspace in AppDomain data: reloads in the same runspace share a session target, while
    # ForEach-Object -Parallel and other runspaces cannot overwrite each other's cluster.
    $stores = [AppDomain]::CurrentDomain.GetData($script:KubeExecutionContextKey)
    if ($null -eq $stores) {
        $stores = [hashtable]::Synchronized(@{})
        [AppDomain]::CurrentDomain.SetData($script:KubeExecutionContextKey, $stores)
    }

    $runspace = [Management.Automation.Runspaces.Runspace]::DefaultRunspace
    $runspaceKey = if ($null -ne $runspace) { $runspace.InstanceId.ToString('N') } else { "thread:$([Environment]::CurrentManagedThreadId)" }
    if (-not $stores.ContainsKey($runspaceKey)) {
        $stores[$runspaceKey] = [hashtable]::Synchronized(@{
            KubeConfigPaths = @()
            Context         = $null
            Namespace       = $null
            Profile         = $null
            ConfigSet       = $null
            Source          = 'Default'
        })
    }
    return $stores[$runspaceKey]
}
function Get-KubeSessionState {
    [CmdletBinding()]
    param()

    # Return a copy. Callers can inspect the session without mutating Core state by reference.
    $store = Get-KubeExecutionContextStore
    [pscustomobject]@{
        PSTypeName      = 'KubeShell.ExecutionContext'
        KubeConfigPaths = @($store.KubeConfigPaths)
        Context         = $store.Context
        Namespace       = $store.Namespace
        Profile         = $store.Profile
        ConfigSet       = $store.ConfigSet
        Source          = $store.Source
    }
}
# Compatibility name retained for the existing shell/configuration surface.  This value describes
# target/session selection; it is intentionally distinct from Runtime.KubeExecutionContext.
function Get-KubeExecutionContext {
    [CmdletBinding()]
    param()

    Get-KubeSessionState
}

function Get-KubeRuntimeExecutionContext {
    [CmdletBinding()]
    param()

    # Runtime execution policy is deliberately a separate DTO from shell target/session state.
    # The current public shell surface has no global impersonation/field-validation policy, so the
    # default is explicit. Individual commands can later construct/pass a richer Runtime context.
    return [KubeShell.Runtime.KubeExecutionContext]::Default
}

function Set-KubeExecutionContext {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]] $KubeConfigPaths,
        [AllowNull()] [string] $Context,
        [AllowNull()] [string] $Namespace,
        [AllowNull()] [string] $Profile,
        [AllowNull()] [string] $ConfigSet,
        [ValidateSet('Default','Environment','ConfigSet','Profile','Scoped','Explicit')] [string] $Source = 'Explicit'
    )

    $store = Get-KubeExecutionContextStore
    if ($PSBoundParameters.ContainsKey('KubeConfigPaths')) { $store.KubeConfigPaths = @($KubeConfigPaths) }
    if ($PSBoundParameters.ContainsKey('Context')) { $store.Context = $Context }
    if ($PSBoundParameters.ContainsKey('Namespace')) { $store.Namespace = $Namespace }
    if ($PSBoundParameters.ContainsKey('Profile')) { $store.Profile = $Profile }
    if ($PSBoundParameters.ContainsKey('ConfigSet')) { $store.ConfigSet = $ConfigSet }
    $store.Source = $Source
    Get-KubeExecutionContext
}
function Restore-KubeExecutionContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ContextState)

    $parameters = @{
        KubeConfigPaths = @($ContextState.KubeConfigPaths)
        Context         = $ContextState.Context
        Namespace       = $ContextState.Namespace
        Profile         = $ContextState.Profile
        ConfigSet       = $ContextState.ConfigSet
        Source          = [string]$ContextState.Source
    }
    Set-KubeExecutionContext @parameters | Out-Null
}
function Get-KubeRuntimeTarget {
    [CmdletBinding()]
    param()

    $state = Get-KubeSessionState
    return [KubeShell.Runtime.KubeTarget]::new(
        [string]$state.Context,
        [string[]]@($state.KubeConfigPaths),
        [string]$state.Namespace,
        [string]$state.Profile,
        [string]$state.ConfigSet,
        [string]$state.Source
    )
}
