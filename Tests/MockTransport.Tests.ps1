BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $fixtures = Join-Path $PSScriptRoot 'Fixtures'

    Import-Module (Join-Path $root 'KubeShell.psd1') -Force

    $global:KubeShellTestDeploymentJson = Get-Content (Join-Path $fixtures 'Deployment.json') -Raw
    $typedDeployment = $global:KubeShellTestDeploymentJson | ConvertFrom-Json -Depth 100
    $typedDeployment.PSObject.TypeNames.Insert(0, 'KubeShell.Deployment')
    $global:KubeShellTestDeploymentResult = $typedDeployment
}

AfterAll {
    Remove-Variable KubeShellTestDeploymentJson -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable KubeShellTestDeploymentResult -Scope Global -ErrorAction SilentlyContinue
    Get-Module KubeShell -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Mocked Runtime resource boundary - mutations' {
    It 'does not cross the Runtime delete boundary under WhatIf' {
        Mock Invoke-KubeRuntimeDelete -ModuleName KubeShell.Operations {
            throw 'resource client must not be reached under WhatIf'
        }

        $pod = [pscustomobject]@{ kind='Pod'; Name='app'; Namespace='demo' }
        { $pod | Remove-KubePod -WhatIf } | Should -Not -Throw

        Should -Invoke Invoke-KubeRuntimeDelete -ModuleName KubeShell.Operations -Times 0 -Exactly
    }

    It 'maps generic delete flags onto Runtime delete options' {
        Mock Invoke-KubeRuntimeDelete -ModuleName KubeShell.Operations { }

        $pod = [pscustomobject]@{ kind='Pod'; Name='app'; Namespace='demo' }
        $result = $pod | Remove-KubeResource -Resource pod -DryRun Server -Force -Confirm:$false

        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.ChangeResult'
        $result.Operation | Should -Be 'Delete'
        $result.DryRun | Should -Be 'Server'

        Should -Invoke Invoke-KubeRuntimeDelete -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'pod' -and
            $Identity.Name -eq 'app' -and
            $Identity.Namespace -eq 'demo' -and
            $Options.DryRun -eq [KubeShell.Runtime.KubeDryRunMode]::Server -and
            $Options.Force -and
            $Options.GracePeriodSeconds -eq 0
        }
    }

    It 'routes deployment scale through the typed Runtime workload operation' {
        Mock Invoke-KubeRuntimeScale -ModuleName KubeShell.Operations {
            [pscustomobject]@{ Resource = [pscustomobject]@{ RawJson = $global:KubeShellTestDeploymentJson } }
        }

        $deployment = [pscustomobject]@{ kind='Deployment'; Name='api'; Namespace='demo' }
        $result = $deployment | Set-KubeDeploymentScale -Replicas 5 -DryRun Server -Confirm:$false

        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.Deployment'
        Should -Invoke Invoke-KubeRuntimeScale -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'deployment' -and
            $Identity.Name -eq 'api' -and
            $Identity.Namespace -eq 'demo' -and
            $Replicas -eq 5 -and
            $DryRun -eq 'Server'
        }
    }

    It 'routes CronJob suspension through the Runtime patch boundary' {
        Mock Invoke-KubeRuntimePatch -ModuleName KubeShell.Operations {
            $global:KubeShellTestDeploymentJson
        }

        $cronJob = [pscustomobject]@{ kind='CronJob'; Name='cleanup'; Namespace='demo' }
        $null = $cronJob | Suspend-KubeCronJob -DryRun Server -Confirm:$false

        Should -Invoke Invoke-KubeRuntimePatch -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'cronjob' -and
            $Identity.ApiVersion -eq 'batch/v1' -and
            $Options.Type -eq [KubeShell.Runtime.KubePatchType]::Merge -and
            $Options.DryRun -eq [KubeShell.Runtime.KubeDryRunMode]::Server -and
            (($PayloadJson | ConvertFrom-Json).spec.suspend -eq $true)
        }
    }
}

Describe 'Mocked Runtime resource boundary - object writes' {
    It 'passes only Kubernetes wire fields to a Runtime server dry-run apply' {
        Mock Invoke-KubeRuntimeApply -ModuleName KubeShell.Manifests {
            $global:KubeShellTestDeploymentJson
        }

        $deployment = $global:KubeShellTestDeploymentJson | ConvertFrom-Json -Depth 100
        # Model the presentation fields that Set-KubeObject must strip before writing.
        $deployment.PSObject.TypeNames.Insert(0,'KubeShell.Deployment')
        $deployment | Add-Member -NotePropertyName Name -NotePropertyValue $deployment.metadata.name -Force
        $deployment | Add-Member -NotePropertyName Namespace -NotePropertyValue $deployment.metadata.namespace -Force
        $deployment | Add-Member -NotePropertyName Healthy -NotePropertyValue $true -Force
        $deployment.spec.replicas = 4

        $result = $deployment | Set-KubeObject -DryRun Server -Confirm:$false
        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.Deployment'

        Should -Invoke Invoke-KubeRuntimeApply -ModuleName KubeShell.Manifests -Times 1 -Exactly -ParameterFilter {
            if ($Identity.Resource -ne 'deployment' -or $Identity.Name -ne 'api' -or $Identity.ApiVersion -ne 'apps/v1') { return $false }
            if ($Options.DryRun -ne [KubeShell.Runtime.KubeDryRunMode]::Server) { return $false }
            if ([string]::IsNullOrWhiteSpace($PayloadJson)) { return $false }

            $wire = $PayloadJson | ConvertFrom-Json -Depth 100
            return (
                $wire.kind -eq 'Deployment' -and
                $wire.metadata.name -eq 'api' -and
                $wire.spec.replicas -eq 4 -and
                -not $wire.PSObject.Properties['Name'] -and
                -not $wire.PSObject.Properties['Healthy'] -and
                -not $wire.PSObject.Properties['status'] -and
                -not $wire.metadata.PSObject.Properties['uid'] -and
                -not $wire.metadata.PSObject.Properties['resourceVersion']
            )
        }
    }

    It 'routes generic patch through Runtime and preserves patch type/dry-run' {
        Mock Invoke-KubeRuntimePatch -ModuleName KubeShell.Manifests {
            $global:KubeShellTestDeploymentJson
        }

        $result = Set-KubeResourcePatch deployment api -Namespace demo -Patch @{ spec=@{ replicas=4 } } -Type Merge -DryRun Server -Confirm:$false
        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.Deployment'

        Should -Invoke Invoke-KubeRuntimePatch -ModuleName KubeShell.Manifests -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'deployment' -and
            $Identity.Name -eq 'api' -and
            $Identity.Namespace -eq 'demo' -and
            $Options.Type -eq [KubeShell.Runtime.KubePatchType]::Merge -and
            $Options.DryRun -eq [KubeShell.Runtime.KubeDryRunMode]::Server -and
            (($PayloadJson | ConvertFrom-Json).spec.replicas -eq 4)
        }
    }
}

Describe 'Mocked Runtime semantic boundary - workloads and streaming helpers' {
    It 'routes rollout restart through the typed Runtime operation' {
        Mock Invoke-KubeRuntimeRolloutRestart -ModuleName KubeShell.Operations {
            [pscustomobject]@{ Resource = [pscustomobject]@{ RawJson = $global:KubeShellTestDeploymentJson }; Diagnostics = @() }
        }

        $deployment = [pscustomobject]@{ kind='Deployment'; Name='api'; Namespace='demo' }
        $result = $deployment | Restart-KubeDeployment -Confirm:$false
        $result.PSObject.TypeNames[0] | Should -Be 'KubeShell.Deployment'

        Should -Invoke Invoke-KubeRuntimeRolloutRestart -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'deployment' -and $Identity.Name -eq 'api' -and $Identity.Namespace -eq 'demo'
        }
    }

    It 'routes image mutation through the typed Runtime operation' {
        Mock Invoke-KubeRuntimeSetImage -ModuleName KubeShell.Operations {
            [pscustomobject]@{ Resource = [pscustomobject]@{ RawJson = $global:KubeShellTestDeploymentJson }; Diagnostics = @() }
        }

        $deployment = [pscustomobject]@{ kind='Deployment'; Name='api'; Namespace='demo' }
        $null = $deployment | Set-KubeImage -Container api -Image 'registry.example/api:v2' -DryRun Client -Confirm:$false

        Should -Invoke Invoke-KubeRuntimeSetImage -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'deployment' -and $Container -eq 'api' -and $Image -eq 'registry.example/api:v2' -and $DryRun -eq 'Client'
        }
    }

    It 'routes rollout undo and status through typed Runtime operations' {
        Mock Invoke-KubeRuntimeRolloutUndo -ModuleName KubeShell.Operations {
            [pscustomobject]@{ Resource = [pscustomobject]@{ RawJson = $global:KubeShellTestDeploymentJson }; Diagnostics = @() }
        }
        Mock Invoke-KubeRuntimeRolloutStatus -ModuleName KubeShell.Operations {
            [pscustomobject]@{ Resource = [pscustomobject]@{ RawJson = $global:KubeShellTestDeploymentJson }; Diagnostics = @() }
        }

        $deployment = [pscustomobject]@{ kind='Deployment'; Name='api'; Namespace='demo' }
        $null = $deployment | Undo-KubeRollout -ToRevision 4 -Confirm:$false
        $null = $deployment | Wait-KubeRollout -Timeout ([timespan]::FromSeconds(12))

        Should -Invoke Invoke-KubeRuntimeRolloutUndo -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'deployment' -and $ToRevision -eq 4
        }
        Should -Invoke Invoke-KubeRuntimeRolloutStatus -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Identity.Resource -eq 'deployment' -and $Timeout.TotalSeconds -eq 12
        }
    }

    It 'routes pod logs through the Runtime log stream' {
        Mock Invoke-KubeRuntimeLog -ModuleName KubeShell.Operations { 'one'; 'two' }
        $pod = [pscustomobject]@{ kind='Pod'; Name='api-1'; Namespace='demo' }

        $lines = @($pod | Get-KubeLog -Container api -Tail 25 -Follow -Prefix)
        $lines | Should -HaveCount 2
        $lines[0] | Should -Be 'one'
        $lines[1] | Should -Be 'two'
        Should -Invoke Invoke-KubeRuntimeLog -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Pod -eq 'api-1' -and $Namespace -eq 'demo' -and $Container -eq 'api' -and $Tail -eq 25 -and $Follow -and $Prefix
        }
    }

    It 'routes pod copy through the Runtime copy service' {
        Mock Invoke-KubeRuntimeCopy -ModuleName KubeShell.Operations { [pscustomobject]@{ Output=''; ErrorOutput='' } }
        $pod = [pscustomobject]@{ kind='Pod'; Name='api-1'; Namespace='demo' }

        $pod | Copy-ToKubePod -Path '/tmp/local.txt' -Destination '/tmp/remote.txt' -Container api -Confirm:$false
        $pod | Copy-FromKubePod -Path '/tmp/remote.txt' -Destination '/tmp/local-copy.txt' -Container api -Confirm:$false

        Should -Invoke Invoke-KubeRuntimeCopy -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Pod -eq 'api-1' -and $Namespace -eq 'demo' -and $LocalPath -eq '/tmp/local.txt' -and $RemotePath -eq '/tmp/remote.txt' -and $ToPod -and $Container -eq 'api'
        }
        Should -Invoke Invoke-KubeRuntimeCopy -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Pod -eq 'api-1' -and $Namespace -eq 'demo' -and $LocalPath -eq '/tmp/local-copy.txt' -and $RemotePath -eq '/tmp/remote.txt' -and -not $ToPod -and $Container -eq 'api'
        }
    }

    It 'routes Pod debug creation through typed Runtime semantics and attaches only to the returned target' {
        Mock Invoke-KubeRuntimeDebug -ModuleName KubeShell.Operations {
            [pscustomobject]@{
                EffectiveWarnings = @()
                Output = $null
                Attachment = [pscustomobject]@{
                    Namespace='demo'; Pod='api-1'; Container='debugger-abcde'
                    Continuation=[KubeShell.Runtime.KubeDebugContinuation]::Attach
                    Interactive=$true; Tty=$true; Quiet=$false
                }
            }
        }
        Mock Invoke-KubeAttachWorker -ModuleName KubeShell.Operations { }

        $pod = [pscustomobject]@{ kind='Pod'; Name='api-1'; Namespace='demo' }
        $pod | Enter-KubeDebugPod -TargetContainer api -Image 'ubuntu:24.04' -Profile netadmin -Command @('/bin/sh') -Confirm:$false

        Should -Invoke Invoke-KubeRuntimeDebug -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Target.Gvr.Resource -eq 'pods' -and $Target.Name -eq 'api-1' -and $Target.Namespace -eq 'demo' -and
            $Image -eq 'ubuntu:24.04' -and $TargetContainer -eq 'api' -and $Profile -eq 'netadmin' -and
            $Command.Count -eq 1 -and $Command[0] -eq '/bin/sh'
        }
        Should -Invoke Invoke-KubeAttachWorker -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'attach' -and $ArgumentList -contains 'pod/api-1' -and
            $ArgumentList -contains 'debugger-abcde' -and $ArgumentList -contains '-i' -and $ArgumentList -contains '-t'
        }
    }

    It 'routes node debug creation through typed Runtime semantics' {
        Mock Invoke-KubeRuntimeDebug -ModuleName KubeShell.Operations {
            [pscustomobject]@{ EffectiveWarnings=@(); Output=$null; Attachment=$null }
        }

        Enter-KubeNode -Node worker-1 -Image 'ubuntu:24.04' -Profile sysadmin -Chroot -Confirm:$false

        Should -Invoke Invoke-KubeRuntimeDebug -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Target.Gvr.Resource -eq 'nodes' -and $Target.Name -eq 'worker-1' -and
            $Target.NamespaceScope.Kind -eq [KubeShell.Runtime.KubeNamespaceScopeKind]::Cluster -and
            $Profile -eq 'sysadmin' -and $Command.Count -eq 3 -and
            $Command[0] -eq 'chroot' -and $Command[1] -eq '/host' -and $Command[2] -eq '/bin/bash'
        }
    }

    It 'falls back to typed logs when a debug container terminates before attach' {
        Mock Invoke-KubeRuntimeDebug -ModuleName KubeShell.Operations {
            [pscustomobject]@{
                EffectiveWarnings = @()
                Output = $null
                Attachment = [pscustomobject]@{
                    Namespace='demo'; Pod='api-1'; Container='debugger-fast'
                    Continuation=[KubeShell.Runtime.KubeDebugContinuation]::Logs
                    Interactive=$true; Tty=$true; Quiet=$false
                }
            }
        }
        Mock Invoke-KubeRuntimeLog -ModuleName KubeShell.Operations { 'done' }
        Mock Invoke-KubeAttachWorker -ModuleName KubeShell.Operations { throw 'attach must not run' }

        $pod = [pscustomobject]@{ kind='Pod'; Name='api-1'; Namespace='demo' }
        $result = @($pod | Enter-KubeDebugPod -Confirm:$false)
        $result | Should -Contain 'done'
        Should -Invoke Invoke-KubeAttachWorker -ModuleName KubeShell.Operations -Times 0 -Exactly
        Should -Invoke Invoke-KubeRuntimeLog -ModuleName KubeShell.Operations -Times 1 -Exactly -ParameterFilter {
            $Pod -eq 'api-1' -and $Namespace -eq 'demo' -and $Container -eq 'debugger-fast'
        }
    }

}

Describe 'Mocked Runtime semantic boundary - diagnostics' {
    It 'routes DNS probes through the typed diagnostics backend' {
        Mock Invoke-KubeRuntimeDnsProbe -ModuleName KubeShell.Diagnostics {
            [pscustomobject]@{ Success=$true; Output='resolved' }
        }

        $result = Test-KubeDns -Namespace demo -Name 'kubernetes.default.svc.cluster.local' -Image 'busybox:1.36' -TimeoutSeconds 15 -Confirm:$false
        $result.Success | Should -BeTrue
        $result.Output | Should -Be 'resolved'
        Should -Invoke Invoke-KubeRuntimeDnsProbe -ModuleName KubeShell.Diagnostics -Times 1 -Exactly -ParameterFilter {
            $Namespace -eq 'demo' -and $Name -eq 'kubernetes.default.svc.cluster.local' -and $Image -eq 'busybox:1.36' -and $Timeout.TotalSeconds -eq 15
        }
    }

    It 'routes pod metrics through the typed diagnostics backend' {
        Mock Invoke-KubeRuntimePodMetrics -ModuleName KubeShell.Diagnostics {
            '{"items":[{"metadata":{"name":"api-1","namespace":"demo"},"timestamp":"2026-09-13T12:00:00Z","containers":[{"usage":{"cpu":"250m","memory":"64Mi"}}]}]}'
        }

        $result = @(Get-KubeTopPod -Namespace demo)
        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'api-1'
        $result[0].CpuMillicores | Should -Be 250
        $result[0].MemoryMiB | Should -Be 64
        Should -Invoke Invoke-KubeRuntimePodMetrics -ModuleName KubeShell.Diagnostics -Times 1 -Exactly -ParameterFilter { $Namespace -eq 'demo' }
    }
}
