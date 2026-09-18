BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $runtimeProject = Join-Path $root 'Runtime/KubeShell.Runtime/KubeShell.Runtime.csproj'
    $managedProject = Join-Path $root 'Backends/KubeShell.KubernetesClient/KubeShell.KubernetesClient.csproj'
    $script:ManagedSourceDirectory = Join-Path $root 'Backends/KubeShell.KubernetesClient/src'
    $processProject = Join-Path $root 'Backends/KubeShell.KubectlProcess/KubeShell.KubectlProcess.csproj'

    $script:RuntimeProjectText = Get-Content -LiteralPath $runtimeProject -Raw
    $script:ManagedProjectText = Get-Content -LiteralPath $managedProject -Raw
    $script:ManagedSourceText = (Get-ChildItem -LiteralPath $script:ManagedSourceDirectory -Filter '*.cs' | Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    $script:ProcessProjectText = Get-Content -LiteralPath $processProject -Raw
}

Describe 'managed backend source boundary' {
    It 'implements the complete Runtime discovery contract including preferred resources' {
        $script:ManagedSourceText | Should -Match 'GetPreferredResourcesAsync'
        $script:ManagedSourceText | Should -Match 'Core\.GetAPIVersionsWithHttpMessagesAsync'
        $script:ManagedSourceText | Should -Match 'Apis\.GetAPIVersionsWithHttpMessagesAsync'
        $script:ManagedSourceText | Should -Match 'PreferredVersion\?\.GroupVersion'
    }

    It 'resolves version-neutral resources across all served versions with shared ambiguity semantics' {
        $discovery = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesDiscoveryService.cs') -Raw
        $runtimeResolution = Get-Content -LiteralPath (Join-Path $root 'Runtime/KubeShell.Runtime/src/Discovery/KubeDiscoveryResolution.cs') -Raw
        $discovery | Should -Match 'resource\.IsResolved[\s\S]*GetApiVersionResourcesCoreAsync'
        $discovery | Should -Match 'GetAllResourcesCoreAsync'
        $discovery | Should -Match 'group\.Versions'
        $discovery | Should -Match 'KubeDiscoveryResolution\.Resolve'
        $discovery | Should -Match 'managed\.discovery\.ambiguous-resource'
        $runtimeResolution | Should -Match 'preferredByGroupResource'
        $runtimeResolution | Should -Match 'logicalCandidates'
        $runtimeResolution | Should -Match 'MatchesResourceToken'
    }

    It 'drops orphan subresources and inherits parent group/version for attached subresources' {
        $discovery = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesDiscoveryService.cs') -Raw
        $discovery | Should -Match 'Where\(pair => pair\.Value\.Base is not null\)'
        $discovery | Should -Match 'string\.IsNullOrWhiteSpace\(sub\.Value\.Group\) \? group : sub\.Value\.Group'
        $discovery | Should -Match 'string\.IsNullOrWhiteSpace\(sub\.Value\.Version\) \? version : sub\.Value\.Version'
    }

    It 'preserves partial preferred discovery when one aggregated API group is unavailable' {
        $discovery = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesDiscoveryService.cs') -Raw
        $discovery | Should -Match 'HttpOperationException\? firstPartialFailure'
        $discovery | Should -Match 'result\.Count == 0.*firstPartialFailure'
    }

    It 'pins the official KubernetesClient package outside Runtime' {
        $script:ManagedProjectText | Should -Match '<PackageReference Include="KubernetesClient" Version="19\.0\.2"\s*/>'
        $script:RuntimeProjectText | Should -Not -Match 'KubernetesClient'
    }

    It 'copies managed NuGet runtime dependencies beside the PowerShell-loaded adapter' {
        $script:ManagedProjectText | Should -Match '<CopyLocalLockFileAssemblies>true</CopyLocalLockFileAssemblies>'
    }

    It 'invalidates cached composition when Managed becomes available late' {
        $loader = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/ManagedBackend.ps1') -Raw
        $composition = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/RuntimeComposition.ps1') -Raw
        $loader | Should -Match 'Reset-KubeRuntimeComposition'
        $loader | Should -Match '\$script:KubeRuntimeHost'
        $composition | Should -Match 'function Reset-KubeRuntimeComposition'
        $composition | Should -Match 'KubeRuntimeHost\.Dispose\(\)'
        $composition | Should -Match 'KubeShell\.Hosting\.KubeShellHost'
    }

    It 'keeps optional adapter load failures from aborting later backend composition' {
        $hosting = Get-Content -LiteralPath (Join-Path $root 'Hosting/KubeShell.Hosting/src/KubeShellHost.cs') -Raw
        $hosting | Should -Match 'catch \(Exception exception\) when \(IsOptionalAdapterLoadFailure\(exception\)\)'
        $hosting | Should -Match 'BadImageFormatException => true'
        $hosting | Should -Match 'FileLoadException => true'
        $hosting | Should -Match 'TypeLoadException => true'
        $hosting | Should -Not -Match 'MissingMethodException => true'
        $hosting | Should -Not -Match 'MissingFieldException => true'
        $hosting | Should -Not -Match 'DllNotFoundException => true'
        $hosting | Should -Not -Match 'EntryPointNotFoundException => true'
        $hosting | Should -Match 'if \(!managedAdded && resolver is not null\)'
        $hosting | Should -Match 'AssemblyLoadContext\.Default\.Resolving -= resolver'
        $hosting | Should -Match 'Configured backend type.*does not implement IKubeBackend'
        $hosting | Should -Match 'does not define expected type'
    }

    It 'resolves managed adapter dependencies once in the Core composition root' {
        $loader = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/ManagedBackend.ps1') -Raw
        $apiModule = Get-Content -LiteralPath (Join-Path $root 'Optional/KubeShell.Api/KubeShell.Api.psm1') -Raw
        $loader | Should -Match 'AssemblyLoadContext\.Default\.Resolving \+= Resolve'
        $loader | Should -Match '\[System\.Runtime\.Loader\.AssemblyLoadContext\]::Default'
        $loader | Should -Match 'LoadFromAssemblyPath'
        $loader | Should -Match 'Path\.Combine\(root, assemblyName\.Name \+ "\.dll"\)'
        $apiModule | Should -Not -Match 'function Initialize-KubeManagedBackendResolver|function Import-KubeManagedBackendAssembly'
    }

    It 'uses generated CustomObjects API instead of reimplementing HTTP paths' {
        $script:ManagedSourceText | Should -Match 'Client\.CustomObjects\.'
        $script:ManagedSourceText | Should -Not -Match 'new HttpRequestMessage'
        $script:ManagedSourceText | Should -Not -Match 'HttpClient\.Send'
    }

    It 'maps server preview to dryRun=All and SSA to ApplyPatch/fieldManager/force' {
        $script:ManagedSourceText | Should -Match 'preview == KubePreviewMode\.Server \? "All" : null'
        $script:ManagedSourceText | Should -Match 'V1Patch\.PatchType\.ApplyPatch'
        $script:ManagedSourceText | Should -Match 'fieldManager: operation\.Options\.FieldManager'
        $script:ManagedSourceText | Should -Match 'fieldValidation: fieldValidation'
        $script:ManagedSourceText | Should -Match 'KubeFieldValidationMode\.Strict => "Strict"'
        $script:ManagedSourceText | Should -Match 'force: operation\.Options\.ForceConflicts'
    }

    It 'keeps client-side preview and client-side apply out of the managed backend contract' {
        $script:ManagedSourceText | Should -Match 'managed\.client-preview'
        $script:ManagedSourceText | Should -Match 'managed\.client-side-apply'
    }

    It 'fails closed for Runtime operations outside the managed executor surface' {
        $backend = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesClientBackend.cs') -Raw
        $backend | Should -Match 'operation is not \(KubeGetOperation or KubeListOperation or KubeCreateOperation or KubeReplaceOperation'
        $backend | Should -Match 'KubeApplyOperation or KubePatchOperation or KubeDeleteOperation'
        $backend | Should -Match 'managed\.operation'
        $backend | Should -Not -Match 'KubeRolloutRestartOperation or KubeScaleOperation'
    }

    It 'does not claim Supported before resolving target, resource and API verb' {
        $backend = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesClientBackend.cs') -Raw
        $backend | Should -Match 'EvaluateLocalSemantics'
        $backend | Should -Match '_discovery[\s\S]*ResolveResourceAsync'
        $backend | Should -Match 'descriptor\.Verbs\.Contains\(verb\)'
        $backend | Should -Match 'KubeErrorKind\.Configuration or KubeErrorKind\.Transport or KubeErrorKind\.Unavailable'
    }

    It 'keeps managed discovery cache isolated by impersonation identity' {
        $factory = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesSessionFactory.cs') -Raw
        $discovery = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesDiscoveryService.cs') -Raw
        $factory | Should -Match 'GetDiscoveryCacheIdentity\(KubeTarget target, KubeExecutionContext executionContext\)'
        $factory | Should -Match 'EffectiveGroups'
        $factory | Should -Match 'EffectiveExtra'
        $discovery | Should -Match 'GetDiscoveryCacheIdentity\(target, executionContext\)'
    }

    It 'normalizes representative Kubernetes HTTP errors to the Runtime taxonomy' {
        $mapper = Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesResponseMapper.cs') -Raw
        $mapper | Should -Match '400 => KubeErrorKind\.InvalidResource'
        $mapper | Should -Match '401 => KubeErrorKind\.Authentication'
        $mapper | Should -Match '403 => KubeErrorKind\.Authorization'
        $mapper | Should -Match '404 => KubeErrorKind\.NotFound'
        $mapper | Should -Match '405 => KubeErrorKind\.Unsupported'
        $mapper | Should -Match '409 => KubeErrorKind\.Conflict'
        $mapper | Should -Match '422 => KubeErrorKind\.InvalidResource'
    }

    It 'keeps session, discovery, execution, and response mapping in separate managed adapter components' {
        foreach ($file in @(
            'KubernetesSessionFactory.cs',
            'KubernetesDiscoveryService.cs',
            'KubernetesOperationExecutor.cs',
            'KubernetesResponseMapper.cs'
        )) {
            Test-Path -LiteralPath (Join-Path $script:ManagedSourceDirectory $file) | Should -BeTrue
        }
        (Get-Content -LiteralPath (Join-Path $script:ManagedSourceDirectory 'KubernetesClientBackend.cs') -Raw) | Should -Not -Match 'LoadKubeConfig|HttpOperationException|ConcurrentDictionary'
    }

    It 'keeps the external kubectl compatibility backend as a separate assembly' {
        $script:ProcessProjectText | Should -Match 'KubeShell\.KubectlProcess'
        $script:ManagedProjectText | Should -Not -Match 'KubectlProcess'
    }
}
