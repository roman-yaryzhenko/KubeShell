# Internal implementation for KubeShell.Core. Loaded into the parent module scope.
# Backend construction/order/lifetime belongs to KubeShell.Hosting. Core owns one host instance
# for its module lifetime and projects only semantic Runtime clients to the rest of PowerShell.

function Reset-KubeRuntimeComposition {
    [CmdletBinding()]
    param()

    if ($null -ne $script:KubeRuntimeHost) {
        try { $script:KubeRuntimeHost.Dispose() } catch { }
    }
    $script:KubeRuntimeHost = $null
}

function Get-KubeRuntimeHost {
    [CmdletBinding()]
    param()

    if ($null -ne $script:KubeRuntimeHost) { return $script:KubeRuntimeHost }

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $moduleRoot '../..'))
    $kubectl = $null
    try { $kubectl = Get-KubeExecutable } catch { }

    $options = [KubeShell.Hosting.KubeShellHostOptions]::new(
        $repositoryRoot,
        $kubectl,
        $true,
        $true,
        $true
    )
    $script:KubeRuntimeHost = [KubeShell.Hosting.KubeShellHost]::Create($options)
    return $script:KubeRuntimeHost
}

function Get-KubeRuntimeOperationClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).OperationClient
}

function New-KubeRuntimeResourceClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).ResourceClient
}

function New-KubeRuntimeWatchClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).WatchClient
}

function New-KubeRuntimeConfigClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).ConfigClient
}

function New-KubeRuntimeDiscoveryClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).DiscoveryClient
}

function New-KubeRuntimeSchemaClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).SchemaClient
}

function New-KubeRuntimeDiagnosticsClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).DiagnosticsClient
}

function New-KubeRuntimeLogClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).LogClient
}

function New-KubeRuntimeCopyClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).CopyClient
}

function New-KubeRuntimeDebugClient {
    [CmdletBinding()]
    param()
    return (Get-KubeRuntimeHost).DebugClient
}
