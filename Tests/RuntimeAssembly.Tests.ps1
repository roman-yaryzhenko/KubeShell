BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $corePath = Join-Path $root 'Modules/KubeShell.Core/KubeShell.Core.psd1'
    Import-Module $corePath -Force
}

AfterAll {
    Get-Module KubeShell.Core -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'KubeShell.Provider portable build boundary' {
    It 'compiles SDK packages against PowerShell Standard rather than the build host runtime' {
        $providerProject = Get-Content -LiteralPath (Join-Path $root 'Optional/KubeShell.Provider/KubeShell.Provider.csproj') -Raw
        $providerBuild = Get-Content -LiteralPath (Join-Path $root 'Optional/KubeShell.Provider/build.ps1') -Raw
        $providerProject | Should -Match '<PackageReference Include="PowerShellStandard\.Library" Version="5\.1\.1"'
        $providerProject | Should -Not -Match '<PackageReference Include="System\.Management\.Automation"'
        $providerProject | Should -Not -Match '\$\(PowerShellHome\)'
        $providerBuild | Should -Not -Match 'PowerShellRuntimeMajor|-p:PowerShellHome='
        $providerBuild | Should -Match 'Provider build must not bundle System\.Management\.Automation'
    }
}

Describe 'KubeShell.Runtime dependency boundary' {
    It 'keeps Add-Type fallback compiler settings aligned with the SDK projects' {
        foreach ($relative in @(
            'Runtime/KubeShell.Runtime/build-with-pwsh.ps1',
            'Backends/KubeShell.KubectlProcess/build-with-pwsh.ps1'
        )) {
            $content = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
            $content | Should -Match '/nullable:enable'
            $content | Should -Match '/langversion:latest'
        }
    }

    It 'keeps Add-Type builds as an SDK-less fallback only' {
        foreach ($relative in @(
            'Runtime/KubeShell.Runtime/build-with-pwsh.ps1',
            'Backends/KubeShell.KubectlProcess/build-with-pwsh.ps1'
        )) {
            $content = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
            $dotnetGuard = $content.IndexOf('Get-Command dotnet')
            $sdkProbe = $content.IndexOf('--list-sdks')
            $sdkBuild = $content.IndexOf("Join-Path `$PSScriptRoot 'build.ps1'")
            $addType = $content.IndexOf('Add-Type -Path')

            $dotnetGuard | Should -BeGreaterThan -1
            $sdkProbe | Should -BeGreaterThan $dotnetGuard
            $sdkBuild | Should -BeGreaterThan $sdkProbe
            $addType | Should -BeGreaterThan $sdkBuild
        }
    }

    It 'keeps explicit Add-Type references additive to the .NET framework set' {
        $content = Get-Content -LiteralPath (Join-Path $root 'Backends/KubeShell.KubectlProcess/build-with-pwsh.ps1') -Raw
        $content | Should -Match '\$PSHOME.*ref'
        $content | Should -Match 'TRUSTED_PLATFORM_ASSEMBLIES'
        $content | Should -Match '-ReferencedAssemblies \$references'
        $content | Should -Not -Match '-ReferencedAssemblies \$runtimeDll'
    }

    It 'does not reference PowerShell, the official Kubernetes client, or native backend assemblies' {
        $references = @([KubeShell.Runtime.KubeTarget].Assembly.GetReferencedAssemblies().Name)
        $references | Should -Not -Contain 'System.Management.Automation'
        $references | Should -Not -Contain 'KubernetesClient'
        $references | Should -Not -Contain 'KubeShell.KubectlProcess'
        $references | Should -Not -Contain 'KubeShell.KubernetesClient'
    }

    It 'keeps transport-specific status details out of Runtime errors' {
        foreach ($name in @('ExitCode','StdErr','HttpStatusCode')) {
            [KubeShell.Runtime.KubeException].GetProperty($name) | Should -BeNullOrEmpty
            [KubeShell.Runtime.KubeError].GetProperty($name) | Should -BeNullOrEmpty
        }
        [KubeShell.Runtime.KubeException].GetProperty('Diagnostics') | Should -Not -BeNullOrEmpty
    }

    It 'separates the semantic operation port from the CRUD resource facade' {
        [KubeShell.Runtime.IKubeOperationClient].GetMethod('ExecuteAsync') | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.IKubeOperationClient].GetMethod('Get') | Should -BeNullOrEmpty
        [KubeShell.Runtime.IKubeResourceClient].GetMethod('Get') | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.IKubeResourceClient].GetMethod('Create') | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.IKubeResourceClient].GetMethod('Replace') | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.IKubeResourceClient].GetMethod('GetAsync') | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.IKubeResourceClient].GetMethod('ReplaceAsync') | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.IKubeResourceClient].GetMethod('ExecuteAsync') | Should -BeNullOrEmpty
        [KubeShell.Runtime.IKubeOperationClient].IsAssignableFrom([KubeShell.Runtime.KubeOperationClient]) | Should -BeTrue
        [KubeShell.Runtime.IKubeOperationClient].IsAssignableFrom([KubeShell.Runtime.KubeResourceClient]) | Should -BeFalse
        [KubeShell.Runtime.IKubeResourceClient].IsAssignableFrom([KubeShell.Runtime.KubeResourceClient]) | Should -BeTrue
    }


    It 'exposes provider-ready selector and execution-context ports without concrete backends' {
        [KubeShell.Runtime.IKubeBackendSelector] | Should -Not -BeNullOrEmpty
        [KubeShell.Runtime.KubeBackendRouter].GetInterfaces() | Should -Contain ([KubeShell.Runtime.IKubeBackendSelector])

        $get = [KubeShell.Runtime.IKubeResourceClient].GetMethod('Get')
        $get.GetParameters()[-1].ParameterType | Should -Be ([KubeShell.Runtime.KubeExecutionContext])
        $create = [KubeShell.Runtime.IKubeResourceClient].GetMethod('Create')
        $create.GetParameters()[-1].ParameterType | Should -Be ([KubeShell.Runtime.KubeExecutionContext])
        $delete = [KubeShell.Runtime.IKubeResourceClient].GetMethod('Delete')
        $delete.GetParameters()[-1].ParameterType | Should -Be ([KubeShell.Runtime.KubeExecutionContext])

        foreach ($name in @('GetAsync','ExistsAsync','TryGetAsync','ListNamesAsync','CreateAsync','ReplaceAsync','ApplyAsync','PatchAsync','DeleteAsync')) {
            $method = [KubeShell.Runtime.IKubeResourceClient].GetMethod($name)
            $method | Should -Not -BeNullOrEmpty
            $method.GetParameters()[-1].ParameterType | Should -Be ([Threading.CancellationToken])
            $method.GetParameters()[-2].ParameterType | Should -Be ([KubeShell.Runtime.KubeExecutionContext])
        }
    }

    It 'keeps PowerShell session state separate from Runtime execution policy' {
        $state = Get-KubeSessionState
        $state | Should -Not -BeOfType ([KubeShell.Runtime.KubeExecutionContext])
        (Get-KubeExecutionContext) | Should -Not -BeOfType ([KubeShell.Runtime.KubeExecutionContext])
        (Get-KubeRuntimeExecutionContext) | Should -BeOfType ([KubeShell.Runtime.KubeExecutionContext])
    }

    It 'segregates diagnostics capabilities into narrow Runtime ports' {
        ('KubeShell.Runtime.IKubeDiagnosticsBackend' -as [type]) | Should -BeNullOrEmpty
        foreach ($type in @(
            [KubeShell.Runtime.IKubeAccessReviewBackend],
            [KubeShell.Runtime.IKubePodMetricsBackend],
            [KubeShell.Runtime.IKubeNodeMetricsBackend],
            [KubeShell.Runtime.IKubeDnsProbeBackend]
        )) {
            $type.IsInterface | Should -BeTrue
        }
    }

    It 'keeps the external kubectl process implementation outside Runtime' {
        [KubeShell.Runtime.IKubeBackend].IsAssignableFrom([KubeShell.Backends.KubectlProcess.KubectlProcessBackend]) | Should -BeTrue
        [KubeShell.Runtime.IKubeBackend].IsAssignableFrom([KubeShell.Backends.KubectlProcess.KubectlProcessTransport]) | Should -BeFalse
        [KubeShell.Backends.KubectlProcess.KubectlProcessBackend].GetMethod('ExecuteRaw') | Should -BeNullOrEmpty
        [KubeShell.Backends.KubectlProcess.KubectlProcessTransport].GetMethod('Execute') | Should -Not -BeNullOrEmpty

        # Add-Type fallback builds use a compiler-generated CLR assembly identity.  The stable
        # boundary is the physical backend DLL and its type namespace, not GetName().Name.
        $backendAssembly = [KubeShell.Backends.KubectlProcess.KubectlProcessBackend].Assembly
        $runtimeAssembly = [KubeShell.Runtime.KubeTarget].Assembly
        [object]::ReferenceEquals($backendAssembly, $runtimeAssembly) | Should -BeFalse
        [IO.Path]::GetFileName($backendAssembly.Location) | Should -Be 'KubeShell.KubectlProcess.dll'
        $runtimeAssembly.GetName().Name | Should -Be 'KubeShell.Runtime'
    }

    It 'projects context and namespace into compatibility kubectl arguments without overriding explicit flags' {
        $target = [KubeShell.Runtime.KubeTarget]::new('prod-admin', [string[]]@('/tmp/a','/tmp/b'), 'payments')

        $implicit = [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::BuildEffectiveArguments(
            $target,
            [string[]]@('get','pods'),
            $true,
            $true
        )
        ($implicit -join '|') | Should -Be '--context|prod-admin|--namespace|payments|get|pods'

        $explicit = [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::BuildEffectiveArguments(
            $target,
            [string[]]@('get','pods','-n','other'),
            $true,
            $true
        )
        ($explicit -join '|') | Should -Be '--context|prod-admin|get|pods|-n|other'
    }

    It 'projects an explicit whitespace context exactly to external kubectl' {
        $target = [KubeShell.Runtime.KubeTarget]::new(' ', [string[]]@('/tmp/a'), 'payments')
        $arguments = [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::BuildEffectiveArguments(
            $target,
            [string[]]@('get','pods'),
            $true,
            $false
        )
        $arguments.Count | Should -Be 4
        $arguments[0] | Should -Be '--context'
        $arguments[1] | Should -BeExactly ' '
    }

    It 'keeps kubectl config free of context and namespace injection' {
        $target = [KubeShell.Runtime.KubeTarget]::new('prod-admin', [string[]]@('/tmp/a'), 'payments')
        $arguments = [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::BuildEffectiveArguments(
            $target,
            [string[]]@('config','current-context'),
            $true,
            $true
        )
        ($arguments -join '|') | Should -Be 'config|current-context'
    }

    It 'keeps configuration persistence outside Runtime and representations immutable' {
        [KubeShell.Runtime.KubeTarget].Assembly.GetType('KubeShell.Runtime.KubeConfigurationStore') | Should -BeNullOrEmpty
        [KubeShell.Runtime.KubeConfigSet].GetProperty('Paths').CanWrite | Should -BeFalse
        [KubeShell.Runtime.KubeProfile].GetProperty('ConfigSet').CanWrite | Should -BeFalse
        [KubeShell.Runtime.KubeProfile].GetProperty('Context').CanWrite | Should -BeFalse
        [KubeShell.Runtime.KubeProfile].GetProperty('Namespace').CanWrite | Should -BeFalse
    }

    It 'resolves profile and config-set targets from Runtime representations' {
        $configSet = [KubeShell.Runtime.KubeConfigSet]::new('prod', [string[]]@('/tmp/prod-a','/tmp/prod-b'))
        $profile = [KubeShell.Runtime.KubeProfile]::new('payments', 'prod', 'prod-admin', 'payments')
        $document = [KubeShell.Runtime.KubeConfigurationDocument]::new(1, [KubeShell.Runtime.KubeConfigSet[]]@($configSet), [KubeShell.Runtime.KubeProfile[]]@($profile))
        $resolver = [KubeShell.Runtime.KubeTargetResolver]::new($document)

        $target = $resolver.ResolveReference('profile:payments')
        $target.Context | Should -Be 'prod-admin'
        $target.DefaultNamespace | Should -Be 'payments'
        $target.Profile | Should -Be 'payments'
        $target.ConfigSet | Should -Be 'prod'
        @($target.KubeConfigPaths).Count | Should -Be 2
    }

    It 'strips API-server-owned fields at the Runtime wire boundary' {
        $json = @'
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"app","namespace":"demo","uid":"u1","resourceVersion":"42","creationTimestamp":"2026-09-11T00:00:00Z"},"spec":{"containers":[]},"status":{"phase":"Running"}}
'@
        $wire = [KubeShell.Runtime.KubeWireSerializer]::PrepareApplyJson($json) | ConvertFrom-Json -Depth 100
        $wire.metadata.name | Should -Be 'app'
        $wire.PSObject.Properties.Name | Should -Not -Contain 'status'
        $wire.metadata.PSObject.Properties.Name | Should -Not -Contain 'uid'
        $wire.metadata.PSObject.Properties.Name | Should -Not -Contain 'resourceVersion'
        $wire.metadata.PSObject.Properties.Name | Should -Not -Contain 'creationTimestamp'
    }
}

Describe 'KubeShell.Runtime semantic contracts' {
    It 'keeps backend provenance out of semantic operation results' {
        [KubeShell.Runtime.KubeOperationResult].GetProperty('BackendId') | Should -BeNullOrEmpty
    }

    It 'uses group-version-resource as the internal Kubernetes address' {
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('apps','v1','deployments')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'api',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('demo'),
            'scale',
            'Deployment'
        )

        $identity.Gvr.Group | Should -Be 'apps'
        $identity.Gvr.Version | Should -Be 'v1'
        $identity.Gvr.Resource | Should -Be 'deployments'
        $identity.Namespace | Should -Be 'demo'
        $identity.Subresource | Should -Be 'scale'
    }

    It 'keeps discovery aliases and subresource verbs as descriptor facts' {
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('apps','v1','deployments')
        $scale = [KubeShell.Runtime.KubeSubresourceDescriptor]::new(
            'scale', 'autoscaling', 'v1', 'Scale', $true, [string[]]@('get','update','patch')
        )
        $descriptor = [KubeShell.Runtime.KubeResourceDescriptor]::Create(
            $gvr, 'Deployment', $true, [string[]]@('get','list','watch','patch'), $null,
            'deployment', [string[]]@('deploy'), [string[]]@('all'),
            [KubeShell.Runtime.KubeSubresourceDescriptor[]]@($scale)
        )

        $descriptor.MatchesResourceToken('deploy') | Should -BeTrue
        $descriptor.MatchesResourceToken('deployment') | Should -BeTrue
        $descriptor.Subresources | Should -Contain 'scale'
        $descriptor.SubresourceDetails['scale'].Verbs | Should -Contain 'patch'
        $descriptor.SubresourceDetails['scale'].Group | Should -Be 'autoscaling'
    }

    It 'distinguishes default, explicit, all-namespaces, and cluster namespace scopes' {
        $target = [KubeShell.Runtime.KubeTarget]::new($null, [string[]]@(), 'payments')
        [KubeShell.Runtime.KubeNamespaceScope]::Default.Resolve($target) | Should -Be 'payments'
        [KubeShell.Runtime.KubeNamespaceScope]::Explicit('demo').Resolve($target) | Should -Be 'demo'
        [KubeShell.Runtime.KubeNamespaceScope]::All.Resolve($target) | Should -BeNullOrEmpty
        [KubeShell.Runtime.KubeNamespaceScope]::Cluster.Resolve($target) | Should -BeNullOrEmpty
    }

    It 'keeps all-namespaces scope collection-only rather than allowing an ambiguous item identity' {
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'pods')
        $query = [KubeShell.Runtime.ResourceQuery]::new($gvr, $null, [KubeShell.Runtime.KubeNamespaceScope]::All)
        $query.NamespaceScope.Kind | Should -Be ([KubeShell.Runtime.KubeNamespaceScopeKind]::All)

        { [KubeShell.Runtime.ResourceIdentity]::new($gvr, 'demo', [KubeShell.Runtime.KubeNamespaceScope]::All, $null, 'Pod') } | Should -Throw

        $target = [KubeShell.Runtime.KubeTarget]::new($null, [string[]]@(), 'default')
        $named = [KubeShell.Runtime.ResourceQuery]::new($gvr, 'demo', [KubeShell.Runtime.KubeNamespaceScope]::All)
        { $named.ToIdentity($target) } | Should -Throw
    }

    It 'keeps KubeTarget kubeconfig paths immutable from callers' {
        $paths = [string[]]@('/tmp/a','/tmp/b')
        $target = [KubeShell.Runtime.KubeTarget]::new('ctx', $paths, 'demo')
        $paths[0] = '/tmp/mutated-source'
        $copy = $target.KubeConfigPaths
        $copy[1] = '/tmp/mutated-return'

        $target.KubeConfigPaths[0] | Should -Be '/tmp/a'
        $target.KubeConfigPaths[1] | Should -Be '/tmp/b'
    }

    It 'preserves exact kubeconfig path bytes instead of trimming execution identity' {
        $exactPaths = [string[]]@(' ', ' /tmp/config', '/tmp/config ')
        $target = [KubeShell.Runtime.KubeTarget]::new('ctx', $exactPaths, 'demo')
        $set = [KubeShell.Runtime.KubeConfigSet]::new('exact', $exactPaths)

        $target.KubeConfigPaths[0] | Should -BeExactly ' '
        $target.KubeConfigPaths[1] | Should -BeExactly ' /tmp/config'
        $target.KubeConfigPaths[2] | Should -BeExactly '/tmp/config '
        $set.Paths[0] | Should -BeExactly ' '
        $set.Paths[1] | Should -BeExactly ' /tmp/config'
        $set.Paths[2] | Should -BeExactly '/tmp/config '

        $contextTarget = [KubeShell.Runtime.KubeTarget]::new(' ', [string[]]@('/tmp/config'), 'demo')
        $contextTarget.Context | Should -BeExactly ' '
    }

    It 'encodes ordered kubeconfig identity without delimiter collisions' {
        $unit = [char]0x1f
        $one = [KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@("/tmp/a${unit}/tmp/b"), 'demo')
        $two = [KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/a','/tmp/b'), 'demo')
        $reversed = [KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/b','/tmp/a'), 'demo')

        [KubeShell.Runtime.KubeTargetIdentityEncoding]::Create($one) | Should -Not -BeExactly ([KubeShell.Runtime.KubeTargetIdentityEncoding]::Create($two))
        [KubeShell.Runtime.KubeTargetIdentityEncoding]::Create($two) | Should -Not -BeExactly ([KubeShell.Runtime.KubeTargetIdentityEncoding]::Create($reversed))
        [KubeShell.Runtime.KubeTargetIdentityEncoding]::Create([KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/a'), 'demo')) | Should -Not -BeExactly ([KubeShell.Runtime.KubeTargetIdentityEncoding]::Create([KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/a','/tmp/a'), 'demo')))
        [KubeShell.Runtime.KubeTargetIdentityEncoding]::Create([KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/a'), 'demo')) | Should -Not -BeExactly ([KubeShell.Runtime.KubeTargetIdentityEncoding]::Create([KubeShell.Runtime.KubeTarget]::new('CTX', [string[]]@('/tmp/a'), 'demo')))
    }

    It 'preserves cluster scope when a server-returned resource has no metadata namespace' {
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'nodes')
        $doc = [System.Text.Json.Nodes.JsonNode]::Parse('{"apiVersion":"v1","kind":"Node","metadata":{"name":"n1"}}').AsObject()
        $resource = [KubeShell.Runtime.KubeResource]::FromDocument($gvr, $doc)

        $resource.Identity.NamespaceScope.Kind | Should -Be ([KubeShell.Runtime.KubeNamespaceScopeKind]::Cluster)
        $resource.Identity.Namespace | Should -BeNullOrEmpty
    }

    It 'owns the Kubernetes document snapshot instead of exposing mutable internal state' {
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'pods')
        $source = [System.Text.Json.Nodes.JsonNode]::Parse('{"apiVersion":"v1","kind":"Pod","metadata":{"name":"p1","namespace":"demo"}}').AsObject()
        $resource = [KubeShell.Runtime.KubeResource]::FromDocument($gvr, $source)
        $source['metadata']['name'] = 'changed-source'
        $copy = $resource.Document
        $copy['metadata']['name'] = 'changed-copy'

        $resource.Identity.Name | Should -Be 'p1'
        $resource.Document['metadata']['name'].ToString() | Should -Be 'p1'
    }

    It 'keeps workload field-manager defaults KubeShell-owned for frontend-neutral Runtime reuse' {
        $identity = [KubeShell.Runtime.ResourceIdentity]::new('deployment','demo','default','Deployment','apps/v1')
        ([KubeShell.Runtime.KubeRolloutRestartOperation]::new($identity)).FieldManager | Should -Be 'kubeshell-rollout'
        ([KubeShell.Runtime.KubeSetImageOperation]::new($identity,'app','registry/app:v2')).FieldManager | Should -Be 'kubeshell-set-image'
    }

    It 'keeps client/server preview separate from client/server apply strategy' {
        $client = [KubeShell.Runtime.KubeApplyOptions]::new(
            [KubeShell.Runtime.KubeApplyStrategy]::ClientSide,
            [KubeShell.Runtime.KubePreviewMode]::Client,
            $null,
            $false
        )
        $client.Strategy | Should -Be ([KubeShell.Runtime.KubeApplyStrategy]::ClientSide)
        $client.Preview | Should -Be ([KubeShell.Runtime.KubePreviewMode]::Client)

        $server = [KubeShell.Runtime.KubeApplyOptions]::new(
            [KubeShell.Runtime.KubeApplyStrategy]::ServerSide,
            [KubeShell.Runtime.KubePreviewMode]::Server,
            $null,
            $true
        )
        $server.FieldManager | Should -Be 'KubeShell'
        $server.ForceConflicts | Should -BeTrue
    }

    It 'rejects client preview for server-side apply before backend routing' {
        {
            [KubeShell.Runtime.KubeApplyOptions]::new(
                [KubeShell.Runtime.KubeApplyStrategy]::ServerSide,
                [KubeShell.Runtime.KubePreviewMode]::Client,
                $null,
                $false
            )
        } | Should -Throw
    }

    It 'normalizes replace concurrency to a non-null default policy' {
        $options = [KubeShell.Runtime.KubeReplaceOptions]::new()
        $options.Concurrency | Should -Not -BeNullOrEmpty
        $options.Concurrency.Mode | Should -Be ([KubeShell.Runtime.KubeConcurrencyMode]::Default)
    }

    It 'models optimistic concurrency independently from SSA force-conflicts' {
        $concurrency = [KubeShell.Runtime.KubeConcurrencyOptions]::new(
            [KubeShell.Runtime.KubeConcurrencyMode]::RequireUnchanged,
            '12345'
        )
        $options = [KubeShell.Runtime.KubePatchOptions]::new(
            [KubeShell.Runtime.KubePatchType]::Merge,
            [KubeShell.Runtime.KubePreviewMode]::Server,
            'KubeShell',
            $concurrency
        )
        $options.Concurrency.Mode | Should -Be ([KubeShell.Runtime.KubeConcurrencyMode]::RequireUnchanged)
        $options.Concurrency.ExpectedResourceVersion | Should -Be '12345'
    }

    It 'represents backend support as supported, unsupported, unavailable, or unknown' {
        $names = @([Enum]::GetNames([KubeShell.Runtime.KubeSupportState]))
        $names.Count | Should -Be 4
        foreach ($name in @('Supported','Unsupported','Unavailable','Unknown')) { $names | Should -Contain $name }
        $unsupported = [KubeShell.Runtime.KubeOperationSupport]::Unsupported('test.unsupported','not implemented')
        $unsupported.State | Should -Be ([KubeShell.Runtime.KubeSupportState]::Unsupported)
        $unsupported.ReasonCode | Should -Be 'test.unsupported'
    }

    It 'preserves indeterminate support as a distinct Runtime error kind' {
        @([Enum]::GetNames([KubeShell.Runtime.KubeErrorKind])) | Should -Contain 'Indeterminate'
        [KubeShell.Runtime.KubeOperationSupport]::Unsupported('test.unsupported','no').ToFailureKind() |
            Should -Be ([KubeShell.Runtime.KubeErrorKind]::Unsupported)
        [KubeShell.Runtime.KubeOperationSupport]::Unavailable('test.unavailable','down').ToFailureKind() |
            Should -Be ([KubeShell.Runtime.KubeErrorKind]::Unavailable)
        [KubeShell.Runtime.KubeOperationSupport]::Unknown('test.unknown','cannot prove').ToFailureKind() |
            Should -Be ([KubeShell.Runtime.KubeErrorKind]::Indeterminate)
    }

    It 'maps Indeterminate to a distinct PowerShell error id without calling it unsupported' {
        $exception = [KubeShell.Runtime.KubeException]::new(
            [KubeShell.Runtime.KubeErrorKind]::Indeterminate,
            'support could not be determined',
            $null, $null, $null, 'routing.indeterminate', $null, $null)
        $record = New-KubeRuntimeErrorRecord -Exception $exception -TargetObject 'pod/demo'
        $record.FullyQualifiedErrorId | Should -Be 'KubeShell.Runtime.Indeterminate'
        $record.CategoryInfo.Category | Should -Be ([Management.Automation.ErrorCategory]::InvalidOperation)
    }

    It 'keeps watch events distinct from ordinary resource results' {
        [Enum]::GetNames([KubeShell.Runtime.KubeWatchEventType]) | Should -Contain 'Deleted'
        [Enum]::GetNames([KubeShell.Runtime.KubeWatchEventType]) | Should -Contain 'Bookmark'
        [Enum]::GetNames([KubeShell.Runtime.KubeWatchEventType]) | Should -Contain 'Error'
    }
}

Describe 'kubectl process compatibility backend support evaluation' {
    It 'supports ordinary generic reads without pretending to be native client-side machinery' {
        $backend = [KubeShell.Backends.KubectlProcess.KubectlProcessBackend]::new('kubectl')
        $target = [KubeShell.Runtime.KubeTarget]::new($null, [string[]]@(), 'demo')
        $query = [KubeShell.Runtime.ResourceQuery]::new('pods', $null, $null, $false, $null, $null, 'v1')
        $operation = [KubeShell.Runtime.KubeListOperation]::new($query)
        $support = $backend.EvaluateAsync($operation, $target, [KubeShell.Runtime.KubeExecutionContext]::Default).AsTask().GetAwaiter().GetResult()
        $support.State | Should -Be ([KubeShell.Runtime.KubeSupportState]::Supported)
    }

    It 'fails closed when external kubectl cannot represent a kubeconfig path in KUBECONFIG' {
        $backend = [KubeShell.Backends.KubectlProcess.KubectlProcessBackend]::new('kubectl')
        $separator = [IO.Path]::PathSeparator
        $target = [KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@("/tmp/a${separator}/tmp/b"), 'demo')
        $query = [KubeShell.Runtime.ResourceQuery]::new('pods', $null, $null, $false, $null, $null, 'v1')
        $operation = [KubeShell.Runtime.KubeListOperation]::new($query)
        $support = $backend.EvaluateAsync($operation, $target, [KubeShell.Runtime.KubeExecutionContext]::Default).AsTask().GetAwaiter().GetResult()

        $support.State | Should -Be ([KubeShell.Runtime.KubeSupportState]::Unsupported)
        $support.ReasonCode | Should -Be 'kubectl-process.kubeconfig-unrepresentable'

        $psi = [Diagnostics.ProcessStartInfo]::new()
        try {
            [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::ApplyEnvironment($target, $psi)
            throw 'Expected KUBECONFIG representability guard.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Unsupported)
            $_.Exception.Code | Should -Be 'kubectl-process.kubeconfig-unrepresentable'
        }
    }

    It 'reports non-default generic patch concurrency as unsupported instead of weakening semantics' {
        $backend = [KubeShell.Backends.KubectlProcess.KubectlProcessBackend]::new('kubectl')
        $target = [KubeShell.Runtime.KubeTarget]::new($null, [string[]]@(), 'demo')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new('deployments','api','demo','Deployment','apps/v1')
        $concurrency = [KubeShell.Runtime.KubeConcurrencyOptions]::new([KubeShell.Runtime.KubeConcurrencyMode]::RequireUnchanged,'42')
        $options = [KubeShell.Runtime.KubePatchOptions]::new([KubeShell.Runtime.KubePatchType]::Merge,[KubeShell.Runtime.KubePreviewMode]::None,$null,$concurrency)
        $operation = [KubeShell.Runtime.KubePatchOperation]::new($identity,'{"spec":{"replicas":2}}',$options)
        $support = $backend.EvaluateAsync($operation, $target, [KubeShell.Runtime.KubeExecutionContext]::Default).AsTask().GetAwaiter().GetResult()
        $support.State | Should -Be ([KubeShell.Runtime.KubeSupportState]::Unsupported)
    }
}
