BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    Import-Module (Join-Path $root 'KubeShell.psd1') -Force

}

AfterAll {
    Get-Module KubeShell -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'KubeShell multiple kubeconfig model' {
    BeforeEach {
        $script:PreviousConfigHome = $env:KUBESHELL_CONFIG_HOME
        $script:PreviousKubeConfig = $env:KUBECONFIG
        $env:KUBESHELL_CONFIG_HOME = Join-Path $TestDrive 'kubeshell-config'
        $env:KUBECONFIG = $null

        $script:DevPath = Join-Path $TestDrive 'dev.yaml'
        $script:ProdPath = Join-Path $TestDrive 'prod.yaml'
        $script:SharedPath = Join-Path $TestDrive 'shared.yaml'
        'apiVersion: v1' | Set-Content -LiteralPath $script:DevPath
        'apiVersion: v1' | Set-Content -LiteralPath $script:ProdPath
        'apiVersion: v1' | Set-Content -LiteralPath $script:SharedPath

        New-KubeConfigSet dev -Path $script:DevPath -Force -Confirm:$false | Out-Null
        New-KubeConfigSet prod -Path @($script:ProdPath,$script:SharedPath) -Force -Confirm:$false | Out-Null
        New-KubeProfile prod-payments -ConfigSet prod -Context prod-admin -Namespace payments -Force -Confirm:$false | Out-Null
        InModuleScope KubeShell.Configuration {
            Set-KubeExecutionContext -KubeConfigPaths @() -Context $null -Namespace $null -Profile $null -ConfigSet $null -Source Default | Out-Null
        }
    }

    AfterEach {
        $env:KUBESHELL_CONFIG_HOME = $script:PreviousConfigHome
        $env:KUBECONFIG = $script:PreviousKubeConfig
        InModuleScope KubeShell.Configuration {
            Set-KubeExecutionContext -KubeConfigPaths @() -Context $null -Namespace $null -Profile $null -ConfigSet $null -Source Default | Out-Null
        }
    }

    It 'stores multiple files as one named kubeconfig set' {
        $set = Get-KubeConfigSet prod
        $set.Name | Should -Be 'prod'
        @($set.Paths).Count | Should -Be 2
        $set.Paths | Should -Contain (Resolve-Path $script:ProdPath).Path
        $set.Paths | Should -Contain (Resolve-Path $script:SharedPath).Path

        $document = Get-Content (Get-KubeConfigurationStorePath) -Raw | ConvertFrom-Json -Depth 20
        @($document.configSets | Where-Object name -EQ 'prod').Count | Should -Be 1
    }

    It 'preserves ordered config-set paths including duplicates' {
        New-KubeConfigSet exact -Path @($script:SharedPath,$script:ProdPath,$script:SharedPath) -Force -Confirm:$false | Out-Null

        $set = Get-KubeConfigSet exact
        @($set.Paths).Count | Should -Be 3
        $set.Paths[0] | Should -BeExactly (Resolve-Path -LiteralPath $script:SharedPath).Path
        $set.Paths[1] | Should -BeExactly (Resolve-Path -LiteralPath $script:ProdPath).Path
        $set.Paths[2] | Should -BeExactly (Resolve-Path -LiteralPath $script:SharedPath).Path
    }

    It 'preserves an explicit whitespace context instead of treating it as ambient current-context' {
        New-KubeProfile exact-context -ConfigSet dev -Context ' ' -Force -Confirm:$false | Out-Null

        $profile = Get-KubeProfile exact-context
        $profile.Context | Should -BeExactly ' '

        $document = Get-Content (Get-KubeConfigurationStorePath) -Raw | ConvertFrom-Json -Depth 20
        @($document.profiles | Where-Object name -CEQ 'exact-context')[0].context | Should -BeExactly ' '
    }

    It 'updates immutable config/profile representations by replacement and persists the new values' {
        Set-KubeConfigSet prod -Path $script:ProdPath -Confirm:$false | Out-Null
        Set-KubeProfile prod-payments -Context $null -Namespace sandbox -Confirm:$false | Out-Null

        $set = Get-KubeConfigSet prod
        @($set.Paths).Count | Should -Be 1
        $profile = Get-KubeProfile prod-payments
        $profile.Context | Should -BeNullOrEmpty
        $profile.Namespace | Should -Be 'sandbox'

        $document = Get-Content (Get-KubeConfigurationStorePath) -Raw | ConvertFrom-Json -Depth 20
        @($document.configSets | Where-Object name -EQ 'prod')[0].paths.Count | Should -Be 1
        @($document.profiles | Where-Object name -EQ 'prod-payments')[0].context | Should -BeNullOrEmpty
    }

    It 'selects a profile without mutating the process KUBECONFIG variable' {
        $env:KUBECONFIG = 'sentinel-value'
        Use-KubeProfile prod-payments -Confirm:$false | Out-Null

        $state = Get-KubeSession
        $state.Profile | Should -Be 'prod-payments'
        $state.ConfigSet | Should -Be 'prod'
        $state.Context | Should -Be 'prod-admin'
        $state.Namespace | Should -Be 'payments'
        @($state.KubeConfigPaths).Count | Should -Be 2
        $env:KUBECONFIG | Should -Be 'sentinel-value'
    }

    It 'injects context and namespace into kubectl arguments while explicit flags win' {
        Use-KubeProfile prod-payments -Confirm:$false | Out-Null

        InModuleScope KubeShell.Configuration {
            (Get-KubeEffectiveArguments @('get','pod')) -join '|' |
                Should -Be '--context|prod-admin|--namespace|payments|get|pod'

            (Get-KubeEffectiveArguments @('get','pod','--namespace','other')) -join '|' |
                Should -Be '--context|prod-admin|get|pod|--namespace|other'

            (Get-KubeEffectiveArguments @('get','pod','--all-namespaces')) -join '|' |
                Should -Be '--context|prod-admin|get|pod|--all-namespaces'

            (Get-KubeEffectiveArguments @('config','view','-o','json')) -join '|' |
                Should -Be 'config|view|-o|json'
        }
    }

    It 'sets KUBECONFIG only on the child process environment' {
        Use-KubeProfile prod-payments -Confirm:$false | Out-Null
        $expected = @((Resolve-Path $script:ProdPath).Path,(Resolve-Path $script:SharedPath).Path) -join [IO.Path]::PathSeparator

        $actual = InModuleScope KubeShell.Configuration {
            $psi = [Diagnostics.ProcessStartInfo]::new()
            Set-KubeProcessEnvironment $psi
            $psi.Environment['KUBECONFIG']
        }

        $actual | Should -Be $expected
        $env:KUBECONFIG | Should -BeNullOrEmpty
    }

    It 'restores the previous target after a scoped profile even when the script throws' {
        Use-KubeConfigSet dev -Context dev-admin -Namespace sandbox -Confirm:$false | Out-Null
        $before = Get-KubeSession

        { Invoke-KubeProfile prod-payments { throw 'scope-test' } } | Should -Throw 'scope-test'

        $after = Get-KubeSession
        $after.ConfigSet | Should -Be $before.ConfigSet
        $after.Context | Should -Be $before.Context
        $after.Namespace | Should -Be $before.Namespace
        $after.Profile | Should -Be $before.Profile
        ($after.KubeConfigPaths -join '|') | Should -Be ($before.KubeConfigPaths -join '|')
    }

    It 'exports KUBECONFIG only when explicitly requested' {
        Use-KubeProfile prod-payments -Confirm:$false | Out-Null
        Set-KubeConfigEnvironment -WhatIf
        $env:KUBECONFIG | Should -BeNullOrEmpty

        $value = Set-KubeConfigEnvironment -PassThru -Confirm:$false
        $env:KUBECONFIG | Should -Be $value
        $value | Should -Match ([regex]::Escape([string][IO.Path]::PathSeparator))
    }

    It 'refuses to export a kubeconfig path that the KUBECONFIG delimiter cannot represent' {
        $separator = [IO.Path]::PathSeparator
        $badPath = "/tmp/a${separator}/tmp/b"
        InModuleScope KubeShell.Configuration -Parameters @{ BadPath = $badPath } {
            param($BadPath)
            Set-KubeExecutionContext -KubeConfigPaths @($BadPath) -Context ctx -Namespace default -Profile $null -ConfigSet $null -Source Explicit | Out-Null
        }

        { Set-KubeConfigEnvironment -Confirm:$false } | Should -Throw '*cannot be represented losslessly in KUBECONFIG*'
    }
}
