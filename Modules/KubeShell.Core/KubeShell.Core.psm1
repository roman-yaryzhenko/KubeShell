Set-StrictMode -Version Latest

$script:KubectlPath = $null
$script:KubeExecutionContextKey = 'KubeShell.ExecutionContexts.v1'
$script:KubeRuntimeHost = $null


$runtimeRoot = Join-Path $PSScriptRoot '../../Runtime/KubeShell.Runtime'
$runtimeDll = Join-Path $runtimeRoot 'bin/Release/net8.0/KubeShell.Runtime.dll'
if (-not ('KubeShell.Runtime.KubeTarget' -as [type])) {
    if (-not (Test-Path -LiteralPath $runtimeDll -PathType Leaf)) {
        $runtimeDll = & (Join-Path $runtimeRoot 'build-with-pwsh.ps1') | Select-Object -Last 1
    }
    Add-Type -Path $runtimeDll
}

$kubectlBackendRoot = Join-Path $PSScriptRoot '../../Backends/KubeShell.KubectlProcess'
$kubectlBackendDll = Join-Path $kubectlBackendRoot 'bin/Release/net8.0/KubeShell.KubectlProcess.dll'
if (-not ('KubeShell.Backends.KubectlProcess.KubectlProcessBackend' -as [type])) {
    if (-not (Test-Path -LiteralPath $kubectlBackendDll -PathType Leaf)) {
        $kubectlBackendDll = & (Join-Path $kubectlBackendRoot 'build-with-pwsh.ps1') | Select-Object -Last 1
    }
    Add-Type -Path $kubectlBackendDll
}

$hostingRoot = Join-Path $PSScriptRoot '../../Hosting/KubeShell.Hosting'
$hostingDll = Join-Path $hostingRoot 'bin/Release/net8.0/KubeShell.Hosting.dll'
if (-not ('KubeShell.Hosting.KubeShellHost' -as [type])) {
    if (-not (Test-Path -LiteralPath $hostingDll -PathType Leaf)) {
        $hostingDll = & (Join-Path $hostingRoot 'build-with-pwsh.ps1') | Select-Object -Last 1
    }
    Add-Type -Path $hostingDll
}

# Core is one module scope, but implementation files are split by reason to change.
# Dot-sourcing preserves existing mocks, script state, and internal call semantics.
$privateScripts = @(
    'ManagedBackend.ps1'
    'ExecutionContext.ps1'
    'RuntimeComposition.ps1'
    'RuntimeErrors.ps1'
    'RuntimeResources.ps1'
    'RuntimeDiscovery.ps1'
    'RuntimeWorkloads.ps1'
    'RuntimeDiagnostics.ps1'
    'RuntimeStreaming.ps1'
    'KubectlCompatibility.ps1'
    'ObjectProjection.ps1'
    'WireConversion.ps1'
    'ResourceResolution.ps1'
)
foreach ($privateScript in $privateScripts) {
    . (Join-Path $PSScriptRoot "Private/$privateScript")
}

# Managed KubernetesClient is optional for source-tree imports, but when packaged it participates
# in the common ordered backend set as the primary semantic backend.
[void](Import-KubeManagedBackendAssembly -Optional)

# A cached backend owns a long-lived child process. Dispose it when this module scope goes away,
# including test-suite reloads, so no kubeshell-kubectl-host process is orphaned.
$ExecutionContext.SessionState.Module.OnRemove = {
    Reset-KubeRuntimeComposition
}

Export-ModuleMember -Function @(
    'Get-KubeExecutable','Import-KubeManagedBackendAssembly','New-KubeManagedExplicitRuntimeClients','Get-KubeExecutionContextStore','Get-KubeSessionState','Get-KubeExecutionContext','Set-KubeExecutionContext','Restore-KubeExecutionContext','Get-KubeRuntimeTarget','Get-KubeRuntimeExecutionContext','New-KubeRuntimeResourceClient','Get-KubeEffectiveArguments','Set-KubeProcessEnvironment','Invoke-KubectlResult','Assert-KubectlSuccess','Invoke-KubectlText','Invoke-KubectlNative','Get-KubeBundledWorkerArguments','New-KubeBundledWorkerProcessStartInfo','Invoke-KubeBundledWorkerNative','Invoke-KubeBundledWorkerResult','Invoke-KubeAttachWorker',
    'ConvertTo-KubeRuntimeDryRunMode','New-KubeRuntimeErrorRecord','New-KubeChangeResult','Invoke-KubeRuntimeGet','Invoke-KubeRuntimeApply','Invoke-KubeRuntimePatch','Invoke-KubeRuntimeDelete','Invoke-KubeRuntimeWatch','ConvertFrom-KubeRuntimeResource','New-KubeRuntimeWatchClient','New-KubeRuntimeConfigClient','Get-KubeRuntimeConfigView','New-KubeRuntimeDiscoveryClient','New-KubeRuntimeSchemaClient','Invoke-KubeRuntimePreferredResources','Invoke-KubeRuntimeResolveResource','Invoke-KubeRuntimeSchema','Invoke-KubeRuntimeRolloutUndo','Invoke-KubeRuntimeRolloutRestart','Invoke-KubeRuntimeScale','Invoke-KubeRuntimeSetImage','Invoke-KubeRuntimeRolloutStatus','New-KubeRuntimeDiagnosticsClient','Invoke-KubeRuntimeAccessReview','Invoke-KubeRuntimePodMetrics','Invoke-KubeRuntimeNodeMetrics','Invoke-KubeRuntimeDnsProbe','New-KubeRuntimeLogClient','Invoke-KubeRuntimeLog','New-KubeRuntimeCopyClient','Invoke-KubeRuntimeCopy','New-KubeRuntimeDebugClient','Invoke-KubeRuntimeDebugRequest','Invoke-KubeRuntimeDebug',
    'Get-KubePropertyValue','ConvertTo-KubeObject','ConvertTo-KubeWireObject','ConvertTo-KubeWireJson','Invoke-KubeTypedGet','Add-KubeNamespaceArguments',
    'Add-KubeSelectorArguments','Add-KubeDryRunArguments','Resolve-KubeIdentity','Resolve-KubeResourceName',
    'ConvertFrom-KubeCpuQuantity','ConvertFrom-KubeMemoryQuantity','Format-KubeAge'
)
