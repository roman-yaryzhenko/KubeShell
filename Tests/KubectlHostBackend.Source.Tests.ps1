BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $backendRoot = Join-Path $root 'Backends/KubeShell.Kubectl'
    $hostRoot = Join-Path $root 'native/kubeshell-kubectl'
    $script:ManagedProject = Get-Content -LiteralPath (Join-Path $backendRoot 'KubeShell.Kubectl.csproj') -Raw
    $script:ManagedSource = (Get-ChildItem -LiteralPath (Join-Path $backendRoot 'src') -Filter '*.cs' -File -Recurse |
        Sort-Object FullName | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    $script:HostModule = Get-Content -LiteralPath (Join-Path $hostRoot 'host/go.mod') -Raw
    $script:ApplySource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/apply.go') -Raw
    $script:SessionSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/session.go') -Raw
    $script:ConfigSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/config.go') -Raw
    $script:DiscoverySource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/discovery.go') -Raw
    $script:SchemaSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/schema.go') -Raw
    $script:RolloutSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/rollout.go') -Raw
    $script:WorkloadSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/workloads.go') -Raw
    $script:DiagnosticsSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/diagnostics.go') -Raw
    $script:LogsSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/logs.go') -Raw
    $script:CopySource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/copy.go') -Raw
    $script:DebugSource = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/debug.go') -Raw
    $script:ManifestSource = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Manifests/KubeShell.Manifests.psm1') -Raw
    $script:SerializationProject = Get-Content -LiteralPath (Join-Path $root 'Libraries/KubeShell.Serialization/KubeShell.Serialization.csproj') -Raw
    $script:SerializationSource = Get-Content -LiteralPath (Join-Path $root 'Libraries/KubeShell.Serialization/src/KubeYamlSerializer.cs') -Raw
    $script:CoreModule = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/KubeShell.Core.psm1') -Raw
    $script:RuntimeComposition = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/RuntimeComposition.ps1') -Raw
    $script:RuntimeStreaming = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/RuntimeStreaming.ps1') -Raw
}

Describe 'kubectl-host backend source boundary' {
    It 'keeps Kubernetes Go dependencies out of the managed adapter and Runtime' {
        $script:ManagedProject | Should -Match 'ProjectReference Include="../../Runtime/KubeShell.Runtime/KubeShell.Runtime.csproj"'
        $script:ManagedProject | Should -Not -Match 'PackageReference'
        $script:ManagedSource | Should -Not -Match '\bDllImport\b|\bLibraryImport\b|\bNativeLibrary\b'
    }

    It 'pins one coherent Kubernetes 0.37 line and its required Go toolchain' {
        $script:HostModule | Should -Match '(?m)^go 1\.26\.0$'
        foreach ($module in @('k8s.io/api','k8s.io/apimachinery','k8s.io/cli-runtime','k8s.io/client-go','k8s.io/kubectl')) {
            $script:HostModule | Should -Match ([regex]::Escape($module) + '\s+v0\.37\.0')
        }
    }

    It 'embeds upstream apply options without executing kubectl Cobra error-exit paths' {
        $script:ApplySource | Should -Match 'cmdapply\.NewApplyFlags'
        $script:ApplySource | Should -Match 'flags\.ToOptions\('
        $script:ApplySource | Should -Match 'options\.Validate\(\)'
        $script:ApplySource | Should -Match 'options\.Run\(\)'
        $script:ApplySource | Should -Not -Match 'NewCmdApply|CheckErr\s*\('
    }

    It 'does not let the host infer ambient kubeconfig state' {
        $script:SessionSource | Should -Match 'len\(req\.KubeconfigPaths\) == 0'
        $script:SessionSource | Should -Match 'Precedence:\s+append\(\[\]string\(nil\), req\.KubeconfigPaths\.\.\.\)'
        $script:SessionSource | Should -Not -Match 'NewDefaultClientConfigLoadingRules|os\.Getenv|RecommendedHomeFile|ExplicitPath'
    }

    It 'keys cached discovery clients by per-call transport identity and timeout' {
        $script:SessionSource | Should -Match 'TimeoutMilliseconds\s+int64'
        $script:SessionSource | Should -Match 'exec\.TimeoutMilliseconds, exec\.UserAgent, exec\.Impersonation'
    }

    It 'does not discard resource serialization failures' {
        $operations = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/operations.go') -Raw
        $operations | Should -Match 'func resultForObject\([^)]*code string\) \(protocol\.OperationResponse, \*protocol\.WireError\)'
        $operations | Should -Not -Match 'raw, _ := json\.Marshal'
    }

    It 'exposes a parameterless composition constructor for reflection-based Hosting activation' {
        $adapter = Get-Content -LiteralPath (Join-Path $root 'Backends/KubeShell.Kubectl/src/KubectlBackend.cs') -Raw
        $adapter | Should -Match 'public\s+KubectlBackend\(\)\s*:\s*this\(null\)'
    }

    It 'loads the IPC backend optionally and keeps a long-lived router with process fallback' {
        $script:CoreModule | Should -Not -Match 'KubeShell\.Kubectl\.dll'
        $script:CoreModule | Should -Match 'KubeShell\.Hosting\.dll'
        $script:RuntimeComposition | Should -Match 'KubeRuntimeHost\.Dispose\(\)'
        $script:RuntimeComposition | Should -Match 'KubeShell\.Hosting\.KubeShellHost'
        $hosting = Get-Content -LiteralPath (Join-Path $root 'Hosting/KubeShell.Hosting/src/KubeShellHost.cs') -Raw
        $hosting | Should -Match 'KubeShell\.Backends\.Kubectl\.KubectlBackend'
        $hosting | Should -Match 'KubeShell\.Backends\.KubectlProcess\.KubectlProcessBackend'
        $hosting | Should -Match 'KubeBackendRouter'
    }


    It 'uses KubeShell discovery token semantics instead of client-go shortcut priority' {
        $errors = Get-Content -LiteralPath (Join-Path $hostRoot 'host/internal/kube/errors.go') -Raw
        $adapter = Get-Content -LiteralPath (Join-Path $backendRoot 'src/Discovery/KubectlDiscoveryService.cs') -Raw
        $script:DiscoverySource | Should -Match 'ServerGroupsAndResourcesWithContext'
        $script:DiscoverySource | Should -Match 'selectResourceDescriptor'
        $script:DiscoverySource | Should -Match 'AmbiguousResourceError'
        $script:DiscoverySource | Should -Match 'NoResourceMatchError'
        $script:DiscoverySource | Should -Match 'if parent == nil[\s\S]*continue'
        $errors | Should -Match 'meta\.IsAmbiguousError'
        $errors | Should -Match 'kubectl\.discovery\.ambiguous-resource'
        $adapter | Should -Match 'kubectl\.discovery\.no-match[\s\S]*return null'
    }

    It 'resolves kubeconfig view and preferred discovery through typed host services' {
        $script:ConfigSource | Should -Match 'rawConfig\.Contexts'
        $script:ManagedSource | Should -Match 'WireProtocol\.Method\.ConfigView'
        $script:DiscoverySource | Should -Match 'ServerPreferredResourcesWithContext'
        $script:ManagedSource | Should -Match 'WireProtocol\.Method\.DiscoverPreferred'

        $configuration = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Configuration/Private/Session.ps1') -Raw
        $context = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Shell/Private/Context.ps1') -Raw
        $resources = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Resources/KubeShell.Resources.psm1') -Raw
        $completion = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Shell/Private/Completion.ps1') -Raw
        $configuration | Should -Not -Match "Invoke-Kubectl.*config|@\('config','view'"
        $context | Should -Not -Match "Invoke-Kubectl.*config|@\('config','view'"
        $resources | Should -Not -Match 'api-resources'
        $completion | Should -Not -Match 'api-resources'
    }

    It 'resolves the conventional kubeconfig path above the native backend boundary' {
        $configuration = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Configuration/Private/Session.ps1') -Raw
        $configuration | Should -Match '\$defaultKubeConfig\s*=\s*Join-Path\s+\(Join-Path\s+\$home\s+''\.kube''\)\s+''config'''
        $configuration | Should -Match 'Set-KubeExecutionContext -KubeConfigPaths @\(\$defaultKubeConfig\)'
        $script:SessionSource | Should -Match 'len\(req\.KubeconfigPaths\) == 0'
        $script:SessionSource | Should -Not -Match 'RecommendedHomeFile|NewDefaultClientConfigLoadingRules'
    }

    It 'serves explain from structured OpenAPI v3 data rather than a kubectl command' {
        $script:SchemaSource | Should -Match 'OpenAPI|openAPI'
        $script:SchemaSource | Should -Match 'PathsWithContext'
        $script:SchemaSource | Should -Match 'SchemaWithContext'
        $script:SchemaSource | Should -Match 'x-kubernetes-group-version-kind'
        $script:SchemaSource | Should -Not -Match 'NewCmdExplain|CheckErr\s*\('
        $script:ManagedSource | Should -Match 'WireProtocol\.Method\.Explain'
        $script:ManagedSource | Should -Match 'KubeSchemaDocument'
    }

    It 'uses upstream polymorphic rollback machinery without executing rollout undo Cobra paths' {
        $script:RolloutSource | Should -Match 'polymorphichelpers\.RollbackerFor'
        $script:RolloutSource | Should -Match 'rollbacker\.Rollback\('
        $script:RolloutSource | Should -Match 'DryRunClient|DryRunServer'
        $script:RolloutSource | Should -Not -Match 'NewCmdRolloutUndo|CheckErr\s*\('
        $script:ManagedSource | Should -Match 'WireProtocol\.Method\.RolloutUndo'
    }

    It 'pins managed YAML serialization and keeps YAML conversion off kubectl and IPC' {
        $script:SerializationProject | Should -Match 'PackageReference Include="YamlDotNet" Version="18\.1\.0"'
        $script:SerializationSource | Should -Match 'YamlStream'
        $script:SerializationSource | Should -Match 'ToJsonDocuments'
        $script:SerializationSource | Should -Match 'ToYaml\('
        foreach ($name in @('Get-KubeYaml','Get-KubeJson','ConvertFrom-KubeYaml','ConvertTo-KubeYaml')) {
            $body = [regex]::Match($script:ManifestSource, "(?s)function $name \\{.*?\\n\\}").Value
            $body | Should -Not -Match 'Invoke-Kubectl|KubectlHost|Invoke-KubeRuntimeSchema'
        }
    }

    It 'keeps generic client preview fail-closed outside reviewed apply/workload semantics' {
        $support = Get-Content -LiteralPath (Join-Path $root 'Backends/KubeShell.Kubectl/src/Support/KubectlSupportEvaluator.cs') -Raw
        $support | Should -Match 'KubeApplyOperation or KubeRolloutUndoOperation or KubeRolloutRestartOperation or KubeScaleOperation or KubeSetImageOperation'
        $support | Should -Match 'KubeOperationSupport\.Unsupported\("kubectl\.client-preview\.operation"'
    }

    It 'keeps workload/debug support evaluation in parity with deterministic executor constraints' {
        $support = Get-Content -LiteralPath (Join-Path $root 'Backends/KubeShell.Kubectl/src/Support/KubectlSupportEvaluator.cs') -Raw
        $support | Should -Match 'EvaluateScale\('
        $support | Should -Match 'SubresourceDetails\.TryGetValue\("scale"'
        $support | Should -Match 'EvaluateRolloutUndo\('
        $support | Should -Match 'EvaluateRolloutRestart\('
        $support | Should -Match 'EvaluateSetImage\('
        $support | Should -Match 'EvaluateRolloutStatus\('
        $support | Should -Match 'EvaluateDebugAsync\('
        $support | Should -Match 'string\.Equals\(descriptor\.Kind,\s*"Pod"'
        $support | Should -Match 'string\.Equals\(descriptor\.Kind,\s*"Node"'
    }

    It 'implements workload commands as typed host operations' {
        $script:WorkloadSource | Should -Match 'polymorphichelpers\.ObjectRestarterFn'
        $script:WorkloadSource | Should -Match 'UpdatePodSpecForObjectFn'
        $script:WorkloadSource | Should -Match 'ScaleClientFn'
        $script:WorkloadSource | Should -Match 'StatusViewerFor'
        $workloads = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/Workloads.ps1') -Raw
        $workloads | Should -Not -Match 'Invoke-Kubectl|Get-KubeExecutable'
        foreach ($call in @('Invoke-KubeRuntimeRolloutRestart','Invoke-KubeRuntimeScale','Invoke-KubeRuntimeSetImage','Invoke-KubeRuntimeRolloutStatus','Invoke-KubeRuntimeRolloutUndo')) {
            $workloads | Should -Match ([regex]::Escape($call))
        }
    }

    It 'keeps manifest lifecycle on managed YAML plus Runtime operations' {
        foreach ($name in @('Set-KubeManifest','Test-KubeManifest','Compare-KubeManifest','Remove-KubeManifest')) {
            $body = [regex]::Match($script:ManifestSource, "(?s)function $name \\{.*?\\n\\}").Value
            $body | Should -Not -Match 'Invoke-Kubectl|Get-KubeExecutable'
        }
        $script:ManifestSource | Should -Match 'KubeYamlSerializer.*CanonicalizeJson'
        $script:ManifestSource | Should -Match 'KubeTextDiff.*Unified'
    }

    It 'implements access, metrics and DNS diagnostics through client-go APIs' {
        $script:DiagnosticsSource | Should -Match 'SelfSubjectAccessReview'
        $script:DiagnosticsSource | Should -Match 'metrics\.k8s\.io/v1beta1'
        $script:DiagnosticsSource | Should -Match 'GetLogs\('
        $diagnostics = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Diagnostics/KubeShell.Diagnostics.psm1') -Raw
        $diagnostics | Should -Not -Match 'Invoke-Kubectl|Get-KubeExecutable'
    }

    It 'streams pod logs and copies files without an external kubectl process' {
        $script:LogsSource | Should -Match 'GetLogs\('
        $script:LogsSource | Should -Match 'OperationID.*EventType.*Text'
        $script:CopySource | Should -Match 'cp\.NewCopyOptions'
        $script:CopySource | Should -Match 'options\.Complete\('
        $script:CopySource | Should -Match 'options\.Validate\(\)'
        $script:CopySource | Should -Match 'options\.Run\(\)'
        $script:CopySource | Should -Not -Match 'NewCmdCp|CheckErr\s*\('
        $logsExec = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/LogsExec.ps1') -Raw
        $copy = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/Copy.ps1') -Raw
        ([regex]::Match($logsExec, '(?s)function Get-KubeLog \{.*?\n\}').Value) | Should -Not -Match 'Invoke-Kubectl'
        $copy | Should -Not -Match 'Invoke-Kubectl|Get-KubeExecutable'
    }


    It 'implements debug as typed semantics and reserves workers for terminal transport' {
        $script:DebugSource | Should -Match 'cmddebug\.NewDebugOptions'
        $script:DebugSource | Should -Match 'options\.Complete\('
        $script:DebugSource | Should -Match 'options\.Validate\(\)'
        $script:DebugSource | Should -Match 'options\.Run\('
        $script:DebugSource | Should -Match 'options\.AttachFunc\s*='
        $script:DebugSource | Should -Match 'waitForDebugContainer'
        $script:DebugSource | Should -Match 'unsupported\("debug\.kind"'
        $script:DebugSource | Should -Not -Match 'NewCmdDebug|CheckErr\s*\('
        $script:ManagedSource | Should -Match 'WireProtocol\.Method\.Debug'
        $script:ManagedSource | Should -Match 'IKubeDebugBackend'

        $runtime = Get-Content -LiteralPath (Join-Path $root 'Runtime/KubeShell.Runtime/src/Debug/KubeDebug.cs') -Raw
        foreach ($field in @('CopyTo','Replace','SetImages','ShareProcesses','CustomProfileJson','ImagePullPolicy','KeepInitContainers')) {
            $runtime | Should -Match $field
        }

        $main = Get-Content -LiteralPath (Join-Path $hostRoot 'host/cmd/kubeshell-kubectl-host/main.go') -Raw
        $main | Should -Match 'case "attach", "exec", "port-forward"'
        $main | Should -Not -Match 'case "debug"'
        $debug = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/Debug.ps1') -Raw
        $debug | Should -Match 'Invoke-KubeRuntimeDebug'
        $debug | Should -Match 'Invoke-KubeAttachWorker'
        $debug | Should -Not -Match 'Invoke-KubeDebugWorker|Invoke-Kubectl'
        $debug | Should -Not -Match 'ValidateSet\([^)]*general[^)]*sysadmin'
        $script:RuntimeStreaming | Should -Match 'function Invoke-KubeRuntimeDebugRequest'
    }

}
