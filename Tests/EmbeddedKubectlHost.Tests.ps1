BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
}

Describe 'kubectl compatibility boundary' {
    It 'keeps the long-lived host explicit and limits compatibility workers to terminal/listener operations' {
        $main = Get-Content -LiteralPath (Join-Path $root 'native/kubeshell-kubectl/host/cmd/kubeshell-kubectl-host/main.go') -Raw
        $main | Should -Match 'hasTransportArgument'
        $main | Should -Match 'parseWorker'
        $main | Should -Match 'case "attach", "exec", "port-forward"'
        $main | Should -Match 'unknown compatibility worker'
        $main | Should -Match 'kubectlcmd\.NewKubectlCommand'
        $main | Should -Not -Match 'runEmbeddedKubectl\(os\.Args\[1:\]\)'
    }

    It 'keeps generic compatibility calls on the external kubectl executable' {
        $compat = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/KubectlCompatibility.ps1') -Raw
        $externalResolver = [regex]::Match($compat, '(?s)function Get-KubeExecutable \{.*?\n\}').Value
        $externalResolver | Should -Match 'Get-Command kubectl'
        $externalResolver | Should -Not -Match 'KubectlHostLocator|kubeshell-kubectl-host'
    }

    It 'uses bundled workers only for attach, interactive exec and port-forward' {
        $compat = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Core/Private/KubectlCompatibility.ps1') -Raw
        $compat | Should -Match 'function Get-KubeBundledHostExecutable'
        $compat | Should -Match 'ValidateSet\(''attach'',''exec'',''port-forward''\)'
        $compat | Should -Match 'function Invoke-KubeBundledWorkerNative'
        $compat | Should -Match 'function Invoke-KubeAttachWorker'
        $compat | Should -Not -Match 'Invoke-KubeDebugWorker|Worker debug'

        $debug = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/Debug.ps1') -Raw
        $debug | Should -Match 'Invoke-KubeRuntimeDebug'
        $debug | Should -Match 'Invoke-KubeAttachWorker'
        $debug | Should -Not -Match 'Invoke-KubeDebugWorker|Worker debug'
        $debug | Should -Not -Match 'Invoke-KubectlNative|Invoke-KubectlText|Invoke-KubectlResult'

        $logsExec = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/LogsExec.ps1') -Raw
        $logsExec | Should -Match 'Invoke-KubeBundledWorkerNative -Worker exec'
        $logsExec | Should -Not -Match 'Invoke-KubectlNative|Invoke-KubectlResult'

        $portForward = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/PortForward.ps1') -Raw
        $portForward | Should -Match 'New-KubeBundledWorkerProcessStartInfo -Worker port-forward'
        $portForward | Should -Not -Match 'Get-KubeExecutable'
    }

    It 'keeps Provider on semantic ObjectModel/Runtime ports and off compatibility workers' {
        $provider = Get-Content -LiteralPath (Join-Path $root 'Optional/KubeShell.Provider/src/KubeShellProvider.cs') -Raw
        $provider | Should -Match 'KubeShellHost\.Create'
        $provider | Should -Match 'IKubeNavigationService'
        $provider | Should -Not -Match 'FileName\s*=|ProcessStartInfo|kubeshell-kubectl-host|KUBESHELL_KUBECTL(?:_HOST)?'
    }

    It 'routes Watch-KubeResource through the Runtime IPC watch contract' {
        $resources = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Resources/KubeShell.Resources.psm1') -Raw
        $watch = [regex]::Match($resources, '(?s)function Watch-KubeResource \{.*?\n\}').Value
        $watch | Should -Match 'Invoke-KubeRuntimeWatch'
        $watch | Should -Not -Match 'Invoke-KubectlJsonStream'
    }

    It 'keeps schema and rollout operations off kubectl process helpers' {
        $resources = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Resources/KubeShell.Resources.psm1') -Raw
        $schema = [regex]::Match($resources, '(?s)function Get-KubeSchema \{.*?function Watch-KubeResource').Value
        $schema | Should -Match 'Invoke-KubeRuntimeSchema'
        $schema | Should -Not -Match 'Invoke-Kubectl'

        $workloads = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Operations/Private/Workloads.ps1') -Raw
        $workloads | Should -Not -Match 'Invoke-Kubectl'
        $workloads | Should -Match 'Invoke-KubeRuntimeRolloutUndo'
        $workloads | Should -Match 'Invoke-KubeRuntimeRolloutRestart'
        $workloads | Should -Match 'Invoke-KubeRuntimeScale'
        $workloads | Should -Match 'Invoke-KubeRuntimeSetImage'
        $workloads | Should -Match 'Invoke-KubeRuntimeRolloutStatus'
    }

    It 'keeps YAML conversion entirely managed' {
        $manifests = Get-Content -LiteralPath (Join-Path $root 'Modules/KubeShell.Manifests/KubeShell.Manifests.psm1') -Raw
        foreach ($name in @('Get-KubeYaml','Get-KubeJson','ConvertFrom-KubeYaml','ConvertTo-KubeYaml')) {
            $body = [regex]::Match($manifests, "(?s)function $name \\{.*?\\n\\}").Value
            $body | Should -Not -Match 'Invoke-Kubectl|Get-KubeExecutable'
        }
        $manifests | Should -Match 'KubeShell\.Serialization\.KubeYamlSerializer'
    }

    It 'keeps ordinary public modules free of external kubectl helper calls' {
        $moduleFiles = Get-ChildItem -LiteralPath (Join-Path $root 'Modules') -Recurse -File -Include '*.ps1','*.psm1' |
            Where-Object {
                $_.FullName -notlike '*Modules/KubeShell.Core/Private/KubectlCompatibility.ps1' -and
                $_.FullName -notlike '*Modules/KubeShell.Core/Private/RuntimeComposition.ps1' -and
                $_.FullName -notlike '*Modules/KubeShell.Core/KubeShell.Core.psm1' -and
                $_.FullName -notlike '*Modules/KubeShell.Shell/Private/Kubectl.ps1'
            }
        foreach ($file in $moduleFiles) {
            $source = Get-Content -LiteralPath $file.FullName -Raw
            $source | Should -Not -Match 'Invoke-Kubectl(Result|Text|Native)|Get-KubeExecutable' -Because $file.FullName
        }
    }

    It 'runs host package tests before producing the helper binary' {
        $build = Get-Content -LiteralPath (Join-Path $root 'native/kubeshell-kubectl/build.ps1') -Raw
        $build | Should -Match "Invoke-GoVisible\s+-Arguments\s+@\('test',\s*'-v',\s*'\./\.\.\.'\)"
        $testIndex = $build.IndexOf("Invoke-GoVisible -Arguments @('test', '-v', './...')", [StringComparison]::Ordinal)
        $buildIndex = $build.IndexOf("Invoke-GoVisible -Arguments @('build', '-trimpath'", [StringComparison]::Ordinal)
        $testIndex | Should -BeGreaterOrEqual 0
        $buildIndex | Should -BeGreaterThan $testIndex
    }
}
