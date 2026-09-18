$managedBackendDll = Join-Path $PSScriptRoot '../Backends/KubeShell.KubernetesClient/bin/Release/net8.0/KubeShell.KubernetesClient.dll'
$managedBackendAvailable = (Test-Path -LiteralPath $managedBackendDll -PathType Leaf) -or [bool](Get-Command dotnet -ErrorAction SilentlyContinue)

BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $fixtures = Join-Path $PSScriptRoot 'Fixtures'

    Import-Module (Join-Path $root 'Optional/KubeShell.Api/KubeShell.Api.psd1') -Force
    Import-Module (Join-Path $root 'Optional/KubeShell.Flux/KubeShell.Flux.psd1') -Force
    Import-Module (Join-Path $root 'Optional/KubeShell.Helm/KubeShell.Helm.psd1') -Force

    $global:KubeShellOptionalPodList = Get-Content (Join-Path $fixtures 'PodList.json') -Raw | ConvertFrom-Json -Depth 100

    # Pester evaluates Describe parameters during discovery, then runs BeforeAll in a
    # separate phase. Re-evaluate availability here instead of relying on discovery scope.
    $managedBackendDllForRun = Join-Path $PSScriptRoot '../Backends/KubeShell.KubernetesClient/bin/Release/net8.0/KubeShell.KubernetesClient.dll'
    $managedBackendCanRun = (Test-Path -LiteralPath $managedBackendDllForRun -PathType Leaf) -or [bool](Get-Command dotnet -ErrorAction SilentlyContinue)
    if ($managedBackendCanRun) { InModuleScope KubeShell.Api { Import-KubeManagedBackendAssembly } }
}

AfterAll {
    Remove-Variable KubeShellOptionalPodList -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Optional managed API backend' -Skip:(-not $managedBackendAvailable) {
    BeforeEach {
        Mock Resolve-KubeApiResourceMetadata -ModuleName KubeShell.Api {
            $parts = $ApiVersion -split '/', 2
            $group = if ($parts.Count -eq 2) { $parts[0] } else { '' }
            $version = if ($parts.Count -eq 2) { $parts[1] } else { $parts[0] }
            [pscustomobject]@{
                Gvr        = [KubeShell.Runtime.GroupVersionResource]::new($group, $version, $Resource)
                Name       = $Resource
                Kind       = if ($Resource -eq 'deployments') { 'Deployment' } elseif ($Resource -eq 'pods') { 'Pod' } else { $null }
                Namespaced = $true
                Verbs      = @('get','list','patch','delete')
                Subresources = @()
            }
        }
    }
    It 'converts Runtime HTTP resources into KubeShell objects' {
        Mock Invoke-KubeApiClientGet -ModuleName KubeShell.Api {
            $list = $global:KubeShellOptionalPodList
            return @($list.items | ForEach-Object { $_ | ConvertTo-Json -Depth 100 -Compress })
        }

        $session = New-KubeApiSession -Server 'https://cluster.example' -Token 'test-token' -DefaultNamespace demo
        $pods = @(Get-KubeApiResource $session pods)

        $pods.Count | Should -Be 2
        $pods[0].PSObject.TypeNames[0] | Should -Be 'KubeShell.Pod'
        $pods[0].Namespace | Should -Be 'demo'
        $session.Token | Should -BeOfType ([Security.SecureString])
        $session.PSObject.Properties.Name | Should -Not -Contain 'Backend'
        $session.Client | Should -BeOfType ([KubeShell.Runtime.KubeResourceClient])
        $session.DiscoveryClient | Should -BeOfType ([KubeShell.Runtime.KubeDiscoveryClient])
        $session.ExecutionContext | Should -BeOfType ([KubeShell.Runtime.KubeExecutionContext])

        Should -Invoke Invoke-KubeApiClientGet -ModuleName KubeShell.Api -Times 1 -Exactly -ParameterFilter {
            $Query.Resource -eq 'pods' -and
            $Query.ApiVersion -eq 'v1' -and
            $Query.Namespace -eq 'demo'
        }
    }

    It 'preserves the selected KubeShell context and namespace for managed kubeconfig bootstrap' {
        $previous = InModuleScope KubeShell.Api { Get-KubeExecutionContext }
        try {
            InModuleScope KubeShell.Api { Set-KubeExecutionContext -Context prod-admin -Namespace payments -KubeConfigPaths @('/tmp/config-a','/tmp/config-b') -Source Explicit | Out-Null }
            $session = New-KubeApiSession -FromKubectlContext
            $session.Context | Should -Be 'prod-admin'
            $session.DefaultNamespace | Should -Be 'payments'
            $session.Target.DefaultNamespace | Should -Be 'payments'
            @($session.Target.KubeConfigPaths).Count | Should -Be 2
            $session.PSObject.Properties.Name | Should -Not -Contain 'Backend'
            $session.Client | Should -BeOfType ([KubeShell.Runtime.KubeResourceClient])
            $session.DiscoveryClient | Should -BeOfType ([KubeShell.Runtime.KubeDiscoveryClient])
            $session.ExecutionContext | Should -BeOfType ([KubeShell.Runtime.KubeExecutionContext])
        }
        finally {
            InModuleScope KubeShell.Api -Parameters @{ Previous = $previous } { Restore-KubeExecutionContext $Previous }
        }
    }

    It 'passes server dry-run through the neutral Runtime patch options' {
        Mock Invoke-KubeApiClientPatch -ModuleName KubeShell.Api {
            $global:KubeShellTestApiPatchResult
        }

        $global:KubeShellTestApiPatchResult = @'
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api","namespace":"demo"},"spec":{"replicas":4}}
'@
        try {
            $session = New-KubeApiSession -Server 'https://cluster.example' -DefaultNamespace demo
            $result = Set-KubeApiResourcePatch $session deployments api -ApiVersion apps/v1 `
                -Patch @{ spec=@{ replicas=4 } } -DryRunServer -Confirm:$false

            $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.Deployment'
            Should -Invoke Invoke-KubeApiClientPatch -ModuleName KubeShell.Api -Times 1 -Exactly -ParameterFilter {
                $Identity.Resource -eq 'deployments' -and
                $Identity.ApiVersion -eq 'apps/v1' -and
                $Options.Type -eq [KubeShell.Runtime.KubePatchType]::Merge -and
                $Options.DryRun -eq [KubeShell.Runtime.KubeDryRunMode]::Server -and
                (($PayloadJson | ConvertFrom-Json).spec.replicas -eq 4)
            }
        }
        finally {
            Remove-Variable KubeShellTestApiPatchResult -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'returns a PowerShell-owned change result for direct API delete' {
        Mock Invoke-KubeApiClientDelete -ModuleName KubeShell.Api { }

        $session = New-KubeApiSession -Server 'https://cluster.example' -DefaultNamespace demo
        $result = Remove-KubeApiResource $session pods app -DryRunServer -Confirm:$false

        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.ChangeResult'
        $result.Operation | Should -Be 'Delete'
        $result.Namespace | Should -Be 'demo'
        $result.DryRun | Should -Be 'Server'

        Should -Invoke Invoke-KubeApiClientDelete -ModuleName KubeShell.Api -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'pods' -and
            $Identity.Name -eq 'app' -and
            $Identity.Namespace -eq 'demo' -and
            $Options.DryRun -eq [KubeShell.Runtime.KubeDryRunMode]::Server
        }
    }

    It 'does not issue a Runtime mutation under WhatIf' {
        Mock Invoke-KubeApiClientDelete -ModuleName KubeShell.Api {
            throw 'Mutation transport must not be reached under WhatIf.'
        }

        $session = New-KubeApiSession -Server 'https://cluster.example' -DefaultNamespace demo
        { Remove-KubeApiResource $session pods app -WhatIf } | Should -Not -Throw

        Should -Invoke Invoke-KubeApiClientDelete -ModuleName KubeShell.Api -Times 0 -Exactly
    }
}

Describe 'Optional Flux extension' {
    It 'maps Flux Kustomizations onto the generic resource layer' {
        Mock Get-KubeResource -ModuleName KubeShell.Flux {
            [pscustomobject]@{ Name='apps'; Namespace='flux-system'; kind='Kustomization' }
        }

        $result = Get-KubeFluxKustomization apps -Namespace flux-system
        $result.Name | Should -Be 'apps'

        Should -Invoke Get-KubeResource -ModuleName KubeShell.Flux -Times 1 -Exactly -ParameterFilter {
            $Resource -eq 'kustomizations.kustomize.toolkit.fluxcd.io' -and
            $Name -eq 'apps' -and
            $Namespace -eq 'flux-system'
        }
    }

    It 'expresses suspension as a merge patch and preserves server dry-run' {
        Mock Set-KubeResourcePatch -ModuleName KubeShell.Flux {
            [pscustomobject]@{ Name=$Name; Namespace=$Namespace }
        }

        $object = [pscustomobject]@{ Name='apps'; Namespace='flux-system'; kind='Kustomization' }
        $null = $object | Suspend-KubeFluxKustomization -DryRun Server -Confirm:$false

        Should -Invoke Set-KubeResourcePatch -ModuleName KubeShell.Flux -Times 1 -Exactly -ParameterFilter {
            $Resource -eq 'kustomization' -and
            $Name -eq 'apps' -and
            $Namespace -eq 'flux-system' -and
            $Type -eq 'Merge' -and
            $DryRun -eq 'Server' -and
            $Patch.spec.suspend -eq $true
        }
    }

    It 'stops before the patch boundary under WhatIf' {
        Mock Set-KubeResourcePatch -ModuleName KubeShell.Flux {
            throw 'Patch boundary must not be reached under WhatIf.'
        }

        $object = [pscustomobject]@{ Name='apps'; Namespace='flux-system'; kind='Kustomization' }
        { $object | Sync-KubeFluxKustomization -WhatIf } | Should -Not -Throw

        Should -Invoke Set-KubeResourcePatch -ModuleName KubeShell.Flux -Times 0 -Exactly
    }
}

Describe 'Optional Helm extension' {
    It 'converts helm list JSON into typed release objects without requiring a helm process' {
        Mock Invoke-HelmJson -ModuleName KubeShell.Helm {
            @(
                [pscustomobject]@{
                    name='grafana'; namespace='monitoring'; revision='3'; updated='2026-09-11T00:00:00Z'
                    status='deployed'; chart='grafana-10.0.0'; app_version='12.0.0'
                }
            )
        }

        $release = Get-KubeHelmRelease grafana -Namespace monitoring
        $release.PSObject.TypeNames[0] | Should -Be 'KubeShell.HelmRelease'
        $release.Name | Should -Be 'grafana'
        $release.Namespace | Should -Be 'monitoring'
        $release.Revision | Should -Be 3

        Should -Invoke Invoke-HelmJson -ModuleName KubeShell.Helm -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join '|') -eq 'list|-o|json|--namespace|monitoring'
        }
    }

    It 'builds a namespace-scoped helm history request' {
        Mock Invoke-HelmJson -ModuleName KubeShell.Helm {
            @(
                [pscustomobject]@{
                    revision='2'; updated='2026-09-11T00:00:00Z'; status='deployed'
                    chart='grafana-10.0.0'; app_version='12.0.0'; description='Upgrade complete'
                }
            )
        }

        $history = @(Get-KubeHelmHistory grafana -Namespace monitoring -Max 8)
        $history.Count | Should -Be 1
        $history[0].PSObject.TypeNames[0] | Should -Be 'KubeShell.HelmRevision'

        Should -Invoke Invoke-HelmJson -ModuleName KubeShell.Helm -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join '|') -eq 'history|grafana|-o|json|--max=8|--namespace|monitoring'
        }
    }
}
