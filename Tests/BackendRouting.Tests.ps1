BeforeAll {
    $script:RoutingFixtureBuildRoot = $null
    $root = Join-Path $PSScriptRoot '..'
    Import-Module (Join-Path $root 'Modules/KubeShell.Core/KubeShell.Core.psd1') -Force
    if (-not ('KubeShell.Tests.RoutingTestBackend' -as [type])) {
        $fixtureSource = Join-Path $PSScriptRoot 'Fixtures/RoutingTestBackend.cs'
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        $hasDotNetSdk = $false
        if ($dotnet) {
            $installedSdks = @(& $dotnet.Source --list-sdks 2>$null)
            $hasDotNetSdk = ($LASTEXITCODE -eq 0 -and $installedSdks.Count -gt 0)
        }

        if ($hasDotNetSdk) {
            # Compile the fixture for the same TFM as KubeShell.Runtime. PowerShell 7.6 runs on
            # a newer CLR, so compiling the fixture against the host TPA set while referencing
            # a net8.0 Runtime produces CS1701 (System.Runtime 8 -> host System.Runtime 10).
            $fixtureProject = Join-Path $PSScriptRoot 'Fixtures/KubeShell.Tests.RoutingFixture.csproj'
            $script:RoutingFixtureBuildRoot = Join-Path ([IO.Path]::GetTempPath()) (
                'kubeshell-routing-fixture-' + [Guid]::NewGuid().ToString('N'))
            $fixtureBin = Join-Path $script:RoutingFixtureBuildRoot 'bin'
            $fixtureObj = Join-Path $script:RoutingFixtureBuildRoot 'obj'
            $buildOutput = @(
                & $dotnet.Source build $fixtureProject -c Release --nologo -v:q `
                    "-p:BaseOutputPath=$fixtureBin$([IO.Path]::DirectorySeparatorChar)" `
                    "-p:BaseIntermediateOutputPath=$fixtureObj$([IO.Path]::DirectorySeparatorChar)" 2>&1
            )
            if ($LASTEXITCODE -ne 0) {
                throw "Routing fixture build failed:`n$($buildOutput -join [Environment]::NewLine)"
            }
            $fixtureDll = Join-Path $fixtureBin 'Release/net8.0/KubeShell.Tests.RoutingFixture.dll'
            Add-Type -Path $fixtureDll
        }
        else {
            # SDK-less module imports build Runtime through Add-Type in this same host, so the
            # loaded Runtime and the host TPA set share one framework identity and can be used
            # directly for the test fixture as well.
            $references = @([KubeShell.Runtime.KubeTarget].Assembly.Location)
            $tpa = [string][AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES')
            if (-not [string]::IsNullOrWhiteSpace($tpa)) {
                $references += $tpa.Split([IO.Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)
            }
            Add-Type -Path $fixtureSource -ReferencedAssemblies @($references | Select-Object -Unique)
        }
    }
    $target = [KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/config'), 'default')
    $context = [KubeShell.Runtime.KubeExecutionContext]::Default
    $operation = [KubeShell.Runtime.KubeGetOperation]::new([KubeShell.Runtime.ResourceIdentity]::new('pod','demo','default','Pod','v1'))

    # Pester 6 evaluates top-level declarations during discovery in a scope that is not
    # the run scope used by It blocks. Install the helper from BeforeAll after Runtime
    # and the fixture type are loaded so every test sees the same function.
    function script:New-RoutingBackend {
        param(
            [string] $Id,
            [KubeShell.Runtime.KubeSupportState] $Operation,
            [KubeShell.Runtime.KubeSupportState] $Capability,
            [bool] $ThrowOnExecute = $false
        )

        [KubeShell.Tests.RoutingTestBackend]::new($Id, $Operation, $Capability, $ThrowOnExecute)
    }
}

AfterAll {
    Get-Module KubeShell.Core -All | Remove-Module -Force -ErrorAction SilentlyContinue
    if ($script:RoutingFixtureBuildRoot -and (Test-Path -LiteralPath $script:RoutingFixtureBuildRoot)) {
        Remove-Item -LiteralPath $script:RoutingFixtureBuildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Function:\New-RoutingBackend -ErrorAction SilentlyContinue
}

Describe 'Capability-aware backend routing' {
    It 'selects the first Supported backend in preference order' {
        $managed = New-RoutingBackend managed Supported Supported
        $go = New-RoutingBackend go Supported Supported
        $process = New-RoutingBackend process Supported Supported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go,$process))
        $selected = $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult()
        $selected.Id | Should -Be 'managed'
        $go.EvaluateCount | Should -Be 0
        $process.EvaluateCount | Should -Be 0
    }

    It 'falls from Unsupported managed to Supported Go' {
        $managed = New-RoutingBackend managed Unsupported Unsupported
        $go = New-RoutingBackend go Supported Supported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
        $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult().Id | Should -Be 'go'
    }

    It 'falls from Unavailable managed to Supported Go' {
        $managed = New-RoutingBackend managed Unavailable Unavailable
        $go = New-RoutingBackend go Supported Supported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
        $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult().Id | Should -Be 'go'
    }

    It 'allows process only after semantic backends decline support' {
        $managed = New-RoutingBackend managed Unsupported Unsupported
        $go = New-RoutingBackend go Unsupported Unsupported
        $process = New-RoutingBackend process Supported Supported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go,$process))
        $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult().Id | Should -Be 'process'
    }

    It 'treats Unknown as non-executable and can continue to explicit Supported' {
        $managed = New-RoutingBackend managed Unknown Unknown
        $go = New-RoutingBackend go Supported Supported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
        $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult().Id | Should -Be 'go'
    }

    It 'surfaces final Unknown operation support as Indeterminate' {
        $managed = New-RoutingBackend managed Unknown Unknown
        $go = New-RoutingBackend go Unsupported Unsupported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))

        try {
            $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult() | Out-Null
            throw 'Expected routing failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Indeterminate)
            $_.Exception.Code | Should -Be 'managed.operation'
        }
    }

    It 'does not let Unavailable hide an unresolved Unknown' {
        foreach ($case in @(
            @{ States = @('Unavailable','Unknown') },
            @{ States = @('Unknown','Unavailable') },
            @{ States = @('Unsupported','Unavailable','Unknown') },
            @{ States = @('Unknown','Unavailable','Unsupported') }
        )) {
            $states = @($case.States)
            $backends = @()
            for ($i = 0; $i -lt $states.Count; $i++) {
                $state = [KubeShell.Runtime.KubeSupportState][Enum]::Parse([KubeShell.Runtime.KubeSupportState], [string]$states[$i])
                $backends += New-RoutingBackend "b$i" $state $state
            }
            $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]$backends)
            try {
                $router.SelectOperationAsync($operation,$target,$context).AsTask().GetAwaiter().GetResult() | Out-Null
                throw 'Expected indeterminate routing failure.'
            }
            catch [KubeShell.Runtime.KubeException] {
                $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Indeterminate)
            }
        }
    }

    It 'does not replay a selected mutation after execution failure' {
        $managed = New-RoutingBackend managed Supported Supported $true
        $go = New-RoutingBackend go Supported Supported
        $client = [KubeShell.Runtime.KubeOperationClient]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
        { $client.Execute($target,$operation,$context) } | Should -Throw
        $managed.ExecuteCount | Should -Be 1
        $go.ExecuteCount | Should -Be 0
        $go.EvaluateCount | Should -Be 0
    }

    It 'uses capability evaluation for specialized semantic interfaces' {
        $podGvr = [KubeShell.Runtime.GroupVersionResource]::FromLegacy('pod','v1')
        $podIdentity = [KubeShell.Runtime.ResourceIdentity]::new('pod','demo','default','Pod','v1')
        $namespace = [KubeShell.Runtime.KubeNamespaceScope]::Explicit('default')
        $schemaRequest = [KubeShell.Runtime.KubeSchemaRequest]::new($podGvr,$null,$false,0)
        $logRequest = [KubeShell.Runtime.KubeLogRequest]::new('demo',$namespace,$null,200,$null,$false,$false,$false,$false)
        $debugRequest = [KubeShell.Runtime.KubeDebugRequest]::new($podIdentity,'busybox',[string[]]@(),$null,'general')
        foreach ($case in @(
            @{ Interface=[KubeShell.Runtime.IKubeDiscoveryBackend]; Request=[KubeShell.Runtime.KubeDiscoveryCapabilityRequest]::new([KubeShell.Runtime.KubeDiscoveryCapabilityKind]::PreferredResources,$false,$null,$null) },
            @{ Interface=[KubeShell.Runtime.IKubeSchemaBackend]; Request=[KubeShell.Runtime.KubeSchemaCapabilityRequest]::new($schemaRequest) },
            @{ Interface=[KubeShell.Runtime.IKubeLogBackend]; Request=[KubeShell.Runtime.KubeLogCapabilityRequest]::new($logRequest) },
            @{ Interface=[KubeShell.Runtime.IKubeDebugBackend]; Request=[KubeShell.Runtime.KubeDebugCapabilityRequest]::new($debugRequest) },
            @{ Interface=[KubeShell.Runtime.IKubeNodeMetricsBackend]; Request=[KubeShell.Runtime.KubeNodeMetricsCapabilityRequest]::new() }
        )) {
            $managed = New-RoutingBackend managed Unsupported Unsupported
            $go = New-RoutingBackend go Supported Supported
            $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
            $method = [KubeShell.Runtime.KubeBackendRouter].GetMethod('SelectCapabilityAsync').MakeGenericMethod($case.Interface)
            $valueTask = $method.Invoke($router, @($case.Request,$target,$context,[Threading.CancellationToken]::None))
            $valueTask.AsTask().GetAwaiter().GetResult().Id | Should -Be 'go'
            $managed.CapabilityEvaluateCount | Should -Be 1
            $go.CapabilityEvaluateCount | Should -Be 1
        }
    }

    It 'surfaces final Unknown capability support as Indeterminate' {
        $managed = New-RoutingBackend managed Unknown Unknown
        $go = New-RoutingBackend go Unsupported Unsupported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
        $podGvr = [KubeShell.Runtime.GroupVersionResource]::FromLegacy('pod','v1')
        $request = [KubeShell.Runtime.KubeSchemaCapabilityRequest]::new(
            [KubeShell.Runtime.KubeSchemaRequest]::new($podGvr,$null,$false,0))

        try {
            $method = [KubeShell.Runtime.KubeBackendRouter].GetMethod('SelectCapabilityAsync').MakeGenericMethod([KubeShell.Runtime.IKubeSchemaBackend])
            $valueTask = $method.Invoke($router, @($request,$target,$context,[Threading.CancellationToken]::None))
            $valueTask.AsTask().GetAwaiter().GetResult() | Out-Null
            throw 'Expected routing failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Indeterminate)
            $_.Exception.Code | Should -Be 'managed.capability'
        }
    }

    It 'rejects a capability request whose typed port does not match the selected interface' {
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@(
            (New-RoutingBackend go Supported Supported)
        ))
        $podGvr = [KubeShell.Runtime.GroupVersionResource]::FromLegacy('pod','v1')
        $schema = [KubeShell.Runtime.KubeSchemaCapabilityRequest]::new(
            [KubeShell.Runtime.KubeSchemaRequest]::new($podGvr,$null,$false,0))
        $method = [KubeShell.Runtime.KubeBackendRouter].GetMethod('SelectCapabilityAsync').MakeGenericMethod([KubeShell.Runtime.IKubeLogBackend])

        { $method.Invoke($router, @($schema,$target,$context,[Threading.CancellationToken]::None)) } | Should -Throw
    }

    It 'makes the process backend enforce semantic guards even when ExecuteAsync is called directly' {
        $process = [KubeShell.Backends.KubectlProcess.KubectlProcessBackend]::new('definitely-not-a-kubectl-binary')
        $strict = [KubeShell.Runtime.KubeExecutionContext]::new(
            $null,
            $null,
            $null,
            [KubeShell.Runtime.KubeFieldValidationMode]::Strict,
            $null)

        try {
            $process.ExecuteAsync($operation,$target,$strict).AsTask().GetAwaiter().GetResult() | Out-Null
            throw 'Expected semantic guard failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Unsupported)
            $_.Exception.Code | Should -Be 'kubectl-process.field-validation'
        }
    }

    It 'maps a direct process Unknown decision to Indeterminate before execution' {
        $process = [KubeShell.Backends.KubectlProcess.KubectlProcessBackend]::new('definitely-not-a-kubectl-binary')
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'pods')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new($gvr,'demo','default','status','Pod')
        $subresourceOperation = [KubeShell.Runtime.KubeGetOperation]::new($identity)

        try {
            $process.ExecuteAsync($subresourceOperation,$target,$context).AsTask().GetAwaiter().GetResult() | Out-Null
            throw 'Expected indeterminate semantic guard failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Indeterminate)
            $_.Exception.Code | Should -Be 'kubectl-process.subresource'
        }
    }


    It 'exposes atomic create through the resource facade without an Exists/Apply preflight' {
        $backend = New-RoutingBackend create Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'configmaps')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'demo',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('default'),
            $null,
            'ConfigMap'
        )
        $payload = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"demo","namespace":"default"},"data":{"key":"value"}}'
        $options = [KubeShell.Runtime.KubeCreateOptions]::new([KubeShell.Runtime.KubePreviewMode]::Server,'kubeshell-provider')
        $created = $client.Create($target,$identity,$payload,$options,$context)

        $backend.EvaluateCount | Should -Be 1
        $backend.ExecuteCount | Should -Be 1
        $backend.LastOperation | Should -BeOfType ([KubeShell.Runtime.KubeCreateOperation])
        $backend.LastOperation.PayloadJson | Should -Be $payload
        $backend.LastOperation.Options.Preview | Should -Be ([KubeShell.Runtime.KubePreviewMode]::Server)
        $backend.LastOperation.Options.FieldManager | Should -Be 'kubeshell-provider'
        $created.Identity.Name | Should -Be 'demo'
        $created.Identity.Namespace | Should -Be 'default'
    }

    It 'rejects create payload identity mismatches before backend selection' {
        $backend = New-RoutingBackend create Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'configmaps')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'expected',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('default'),
            $null,
            'ConfigMap'
        )
        $payload = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"other","namespace":"default"}}'

        try {
            $client.Create($target,$identity,$payload,[KubeShell.Runtime.KubeCreateOptions]::new(),$context) | Out-Null
            throw 'Expected create identity validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::InvalidResource)
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'exposes replace through the resource facade without rewriting it into apply' {
        $backend = New-RoutingBackend replace Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('apps', 'v1', 'deployments')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'api',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('payments'),
            $null,
            'Deployment'
        )
        $payload = '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api","namespace":"payments","resourceVersion":"42"},"spec":{"replicas":3}}'
        $concurrency = [KubeShell.Runtime.KubeConcurrencyOptions]::new(
            [KubeShell.Runtime.KubeConcurrencyMode]::RequireUnchanged,
            '42'
        )
        $options = [KubeShell.Runtime.KubeReplaceOptions]::new(
            [KubeShell.Runtime.KubePreviewMode]::Server,
            'kubeshell-provider',
            $concurrency
        )

        $replaced = $client.ReplaceAsync($target,$identity,$payload,$options,$context,[Threading.CancellationToken]::None).AsTask().GetAwaiter().GetResult()

        $backend.EvaluateCount | Should -Be 1
        $backend.ExecuteCount | Should -Be 1
        $backend.LastOperation | Should -BeOfType ([KubeShell.Runtime.KubeReplaceOperation])
        $backend.LastOperation.PayloadJson | Should -Be $payload
        $backend.LastOperation.Options.Preview | Should -Be ([KubeShell.Runtime.KubePreviewMode]::Server)
        $backend.LastOperation.Options.Concurrency.Mode | Should -Be ([KubeShell.Runtime.KubeConcurrencyMode]::RequireUnchanged)
        $backend.LastOperation.Options.Concurrency.ExpectedResourceVersion | Should -Be '42'
        $replaced.Identity.Name | Should -Be 'api'
        $replaced.Identity.Namespace | Should -Be 'payments'
    }

    It 'rejects replace payload identity mismatches before backend selection' {
        $backend = New-RoutingBackend replace Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('apps', 'v1', 'deployments')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'expected',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('payments'),
            $null,
            'Deployment'
        )
        $payload = '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"other","namespace":"payments"}}'

        try {
            $client.Replace($target,$identity,$payload,[KubeShell.Runtime.KubeReplaceOptions]::new(),$context) | Out-Null
            throw 'Expected replace identity validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::InvalidResource)
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'fails closed when a named resource query also carries selectors' {
        $backend = New-RoutingBackend query Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'pods')
        $query = [KubeShell.Runtime.ResourceQuery]::new(
            $gvr,
            'demo',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('default'),
            'app=demo',
            $null,
            $null
        )

        { $client.Get($target,$query,$context) | Out-Null } | Should -Throw
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'does not collapse all-namespaces ListNames results into ambiguous bare names' {
        $backend = New-RoutingBackend query Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'pods')
        $query = [KubeShell.Runtime.ResourceQuery]::new(
            $gvr,
            $null,
            [KubeShell.Runtime.KubeNamespaceScope]::All,
            $null,
            $null,
            $null
        )

        { $client.ListNames($target,$query,$context) | Out-Null } | Should -Throw
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'normalizes malformed patch JSON before backend selection' {
        $backend = New-RoutingBackend patch Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'configmaps')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'demo',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('default'),
            $null,
            'ConfigMap'
        )

        try {
            $client.Patch($target,$identity,'{"data":',[KubeShell.Runtime.KubePatchOptions]::new(),$context) | Out-Null
            throw 'Expected patch JSON validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::Serialization)
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'validates mutation payload namespace against the target default namespace before routing' {
        $backend = New-RoutingBackend create Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'configmaps')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'demo',
            [KubeShell.Runtime.KubeNamespaceScope]::Default,
            $null,
            'ConfigMap'
        )
        $payload = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"demo","namespace":"other"}}'

        try {
            $client.Create($target,$identity,$payload,[KubeShell.Runtime.KubeCreateOptions]::new(),$context) | Out-Null
            throw 'Expected effective-namespace identity validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::InvalidResource)
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'requires an explicit identity namespace when the target default namespace is unresolved' {
        $backend = New-RoutingBackend create Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $unresolvedTarget = [KubeShell.Runtime.KubeTarget]::new('ctx', [string[]]@('/tmp/config'), $null)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'configmaps')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'demo',
            [KubeShell.Runtime.KubeNamespaceScope]::Default,
            $null,
            'ConfigMap'
        )
        $payload = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"demo","namespace":"other"}}'

        try {
            $client.Create($unresolvedTarget,$identity,$payload,[KubeShell.Runtime.KubeCreateOptions]::new(),$context) | Out-Null
            throw 'Expected unresolved-default namespace validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::InvalidResource)
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'rejects incomplete RequireUnchanged concurrency before backend selection' {
        $backend = New-RoutingBackend replace Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('apps', 'v1', 'deployments')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'api',
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit('payments'),
            $null,
            'Deployment'
        )
        $payload = '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api","namespace":"payments","resourceVersion":"42"},"spec":{"replicas":3}}'
        $concurrency = [KubeShell.Runtime.KubeConcurrencyOptions]::new(
            [KubeShell.Runtime.KubeConcurrencyMode]::RequireUnchanged,
            $null
        )
        $options = [KubeShell.Runtime.KubeReplaceOptions]::new(
            [KubeShell.Runtime.KubePreviewMode]::None,
            $null,
            $concurrency
        )

        try {
            $client.Replace($target,$identity,$payload,$options,$context) | Out-Null
            throw 'Expected concurrency validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::InvalidResource)
            $_.Exception.Code | Should -Be 'concurrency.resource-version-required'
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'rejects namespace metadata on cluster-scoped mutation payloads before routing' {
        $backend = New-RoutingBackend create Supported Supported
        $client = [KubeShell.Runtime.KubeResourceClient]::new([KubeShell.Runtime.IKubeBackend]$backend)
        $gvr = [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'nodes')
        $identity = [KubeShell.Runtime.ResourceIdentity]::new(
            $gvr,
            'node-1',
            [KubeShell.Runtime.KubeNamespaceScope]::Cluster,
            $null,
            'Node'
        )
        $payload = '{"apiVersion":"v1","kind":"Node","metadata":{"name":"node-1","namespace":"default"}}'

        try {
            $client.Create($target,$identity,$payload,[KubeShell.Runtime.KubeCreateOptions]::new(),$context) | Out-Null
            throw 'Expected cluster-scope identity validation failure.'
        }
        catch [KubeShell.Runtime.KubeException] {
            $_.Exception.Kind | Should -Be ([KubeShell.Runtime.KubeErrorKind]::InvalidResource)
        }
        $backend.EvaluateCount | Should -Be 0
        $backend.ExecuteCount | Should -Be 0
    }

    It 'routes workload operations by capability rather than interface presence' {
        $managed = New-RoutingBackend managed Unsupported Unsupported
        $go = New-RoutingBackend go Supported Supported
        $router = [KubeShell.Runtime.KubeBackendRouter]::new([KubeShell.Runtime.IKubeBackend[]]@($managed,$go))
        $rollout = [KubeShell.Runtime.KubeRolloutRestartOperation]::new(
            [KubeShell.Runtime.ResourceIdentity]::new('deployment','demo','default','Deployment','apps/v1'),
            [KubeShell.Runtime.KubePreviewMode]::None,
            'kubeshell-rollout')
        $router.SelectOperationAsync($rollout,$target,$context).AsTask().GetAwaiter().GetResult().Id | Should -Be 'go'
        $managed.EvaluateCount | Should -Be 1
        $go.EvaluateCount | Should -Be 1
    }

}
