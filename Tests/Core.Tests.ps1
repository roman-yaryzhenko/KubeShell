BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $script:CorePath = Join-Path $root 'Modules/KubeShell.Core/KubeShell.Core.psd1'
    Import-Module $script:CorePath -Force

    $fixtures = Join-Path $PSScriptRoot 'Fixtures'
    $global:KubeShellCorePodListJson = Get-Content (Join-Path $fixtures 'PodList.json') -Raw
    $global:KubeShellCoreDeploymentJson = Get-Content (Join-Path $fixtures 'Deployment.json') -Raw
}

AfterAll {
    Remove-Variable KubeShellCorePodListJson -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable KubeShellCoreDeploymentJson -Scope Global -ErrorAction SilentlyContinue
    Get-Module KubeShell.Core -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'KubeShell Core object model' {
    It 'parses Kubernetes CPU quantities' {
        ConvertFrom-KubeCpuQuantity '500m' | Should -Be 0.5
        ConvertFrom-KubeCpuQuantity '2' | Should -Be 2.0
    }

    It 'parses Kubernetes memory quantities' {
        ConvertFrom-KubeMemoryQuantity '1Gi' | Should -Be 1GB
        ConvertFrom-KubeMemoryQuantity '256Mi' | Should -Be 256MB
    }

    It 'enriches a Pod without discarding the raw Kubernetes shape' {
        $pod = [pscustomobject]@{
            apiVersion='v1'; kind='Pod'
            metadata=[pscustomobject]@{ name='app'; namespace='demo'; creationTimestamp=[datetimeoffset]::Now.AddMinutes(-1).ToString('o') }
            spec=[pscustomobject]@{ nodeName='n1'; containers=@([pscustomobject]@{name='app';image='x'}) }
            status=[pscustomobject]@{ phase='Running'; containerStatuses=@([pscustomobject]@{name='app';ready=$true;restartCount=0}) }
        }
        $result = ConvertTo-KubeObject $pod
        $result.Name | Should -Be 'app'
        $result.Namespace | Should -Be 'demo'
        $result.Ready | Should -Be '1/1'
        $result.Healthy | Should -BeTrue
        $result.spec.nodeName | Should -Be 'n1'
        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.Pod'
    }

    It 'keeps KubeShell presentation fields out of apply payloads' {
        $pod = [pscustomobject]@{
            apiVersion='v1'; kind='Pod'
            metadata=[pscustomobject]@{
                name='app'; namespace='demo'; uid='server-uid'; resourceVersion='42'
                creationTimestamp=[datetimeoffset]::Now.AddMinutes(-1).ToString('o')
            }
            spec=[pscustomobject]@{ nodeName='n1'; containers=@([pscustomobject]@{name='app';image='x'}) }
            status=[pscustomobject]@{ phase='Running'; containerStatuses=@([pscustomobject]@{name='app';ready=$true;restartCount=0}) }
        }
        $result = ConvertTo-KubeObject $pod
        $wire = ConvertTo-KubeWireObject $result -ForApply
        $wire.PSObject.Properties.Name | Should -Not -Contain 'Name'
        $wire.PSObject.Properties.Name | Should -Not -Contain 'Healthy'
        $wire.PSObject.Properties.Name | Should -Not -Contain 'status'
        $wire.metadata.PSObject.Properties.Name | Should -Not -Contain 'uid'
        $wire.metadata.PSObject.Properties.Name | Should -Not -Contain 'resourceVersion'
        $wire.spec.nodeName | Should -Be 'n1'
    }
}

Describe 'KubeShell Core transport errors' {
    It 'turns a non-zero kubectl result into a structured terminating error' {
        Mock Invoke-KubectlResult -ModuleName KubeShell.Core {
            [pscustomobject]@{
                ExitCode  = 1
                StdOut    = ''
                StdErr    = 'Error from server (NotFound): pods "missing" not found'
                Arguments = @('get','pod','missing')
            }
        }

        { Invoke-KubectlText -ArgumentList @('get','pod','missing') } |
            Should -Throw -ErrorId 'KubeShell.KubectlFailed'
    }
}


Describe 'KubeShell Core typed resource queries' {
    BeforeEach {
        Mock Invoke-KubeRuntimeGet -ModuleName KubeShell.Core {
            if ($Query.Resource -eq 'deployment') {
                return $global:KubeShellCoreDeploymentJson
            }

            $list = $global:KubeShellCorePodListJson | ConvertFrom-Json -Depth 100
            return @($list.items | ForEach-Object { $_ | ConvertTo-Json -Depth 100 -Compress })
        }
    }

    It 'builds a namespaced pod query and converts Runtime resources into typed objects' {
        $pods = @(Invoke-KubeTypedGet -Resource pod -Namespace demo -LabelSelector app=web -FieldSelector status.phase=Running)

        $pods.Count | Should -Be 2
        $pods[0].PSObject.TypeNames[0] | Should -Be 'KubeShell.Pod'
        $pods[0].Name | Should -Be 'web-7f6d8d9c8b-a1b2c'
        $pods[0].Namespace | Should -Be 'demo'
        $pods[0].Node | Should -Be 'node-a'
        $pods[0].Ready | Should -Be '1/1'
        $pods[0].Restarts | Should -Be 1
        $pods[0].Healthy | Should -BeTrue
        $pods[1].Healthy | Should -BeFalse

        Should -Invoke Invoke-KubeRuntimeGet -ModuleName KubeShell.Core -Times 1 -Exactly -ParameterFilter {
            $Query.Resource -eq 'pod' -and
            $Query.Namespace -eq 'demo' -and
            $Query.LabelSelector -eq 'app=web' -and
            $Query.FieldSelector -eq 'status.phase=Running' -and
            -not $Query.AllNamespaces
        }
    }

    It 'sets all-namespaces on the neutral ResourceQuery' {
        $null = @(Invoke-KubeTypedGet -Resource pod -AllNamespaces)

        Should -Invoke Invoke-KubeRuntimeGet -ModuleName KubeShell.Core -Times 1 -Exactly -ParameterFilter {
            $Query.Resource -eq 'pod' -and $Query.AllNamespaces -and [string]::IsNullOrWhiteSpace($Query.Namespace)
        }
    }

    It 'keeps a named deployment as a single typed object' {
        $deployment = Invoke-KubeTypedGet -Resource deployment -Name api -Namespace demo

        $deployment.PSObject.TypeNames[0] | Should -Be 'KubeShell.Deployment'
        $deployment.Name | Should -Be 'api'
        $deployment.Desired | Should -Be 3
        $deployment.Available | Should -Be 3
        $deployment.Healthy | Should -BeTrue

        Should -Invoke Invoke-KubeRuntimeGet -ModuleName KubeShell.Core -Times 1 -Exactly -ParameterFilter {
            $Query.Resource -eq 'deployment' -and $Query.Name -eq 'api' -and $Query.Namespace -eq 'demo'
        }
    }
}

Describe 'KubeShell Core executable resolution' {
    BeforeEach {
        InModuleScope KubeShell.Core { $script:KubectlPath = $null }
    }

    AfterEach {
        InModuleScope KubeShell.Core { $script:KubectlPath = $null }
    }

    It 'uses one executable when PATH exposes kubectl through multiple entries' {
        Mock Get-Command -ModuleName KubeShell.Core {
            @(
                [pscustomobject]@{ Source='/usr/bin/kubectl' },
                [pscustomobject]@{ Source='/bin/kubectl' }
            )
        } -ParameterFilter { $Name -eq 'kubectl' }

        Get-KubeExecutable | Should -Be '/usr/bin/kubectl'
    }
}

Describe 'KubeShell Core execution-context lifetime' {
    It 'keeps execution context across a Core module reload in the same runspace' {
        Set-KubeExecutionContext -KubeConfigPaths @('/tmp/dev.yaml') -Context dev-admin -Namespace sandbox -Profile dev -ConfigSet dev -Source Profile | Out-Null
        Import-Module $script:CorePath -Force

        $state = Get-KubeExecutionContext
        $state.Profile | Should -Be 'dev'
        $state.ConfigSet | Should -Be 'dev'
        $state.Context | Should -Be 'dev-admin'
        $state.Namespace | Should -Be 'sandbox'
    }
}
