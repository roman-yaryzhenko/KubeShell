BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    Import-Module (Join-Path $root 'KubeShell.psd1') -Force
}

AfterAll {
    Get-Module KubeShell -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'KubeShell safety surface' {
    It 'accepts WhatIf on destructive commands without invoking kubectl' {
        $pod = [pscustomobject]@{ kind='Pod'; Name='app'; Namespace='demo' }
        { $pod | Remove-KubePod -WhatIf } | Should -Not -Throw
    }

    It 'exposes terse shell aliases without duplicating the cmdlet-shaped API' {
        (Get-Alias kwatch).Definition | Should -Be 'Watch-KubeResource'
        (Get-Alias kx).Definition | Should -Be 'Invoke-KubeExec'
    }
}

Describe 'KubeShell persistent bookmarks' {
    It 'persists bookmark data outside module memory' {
        $previous = $env:KUBESHELL_CONFIG_HOME
        $configHome = Join-Path $TestDrive 'kubeshell-config'
        try {
            $env:KUBESHELL_CONFIG_HOME = $configHome
            Set-KubeBookmark demo-bookmark -Context demo-context -Namespace demo -Resource pod -ResourceName app | Out-Null

            $path = Join-Path $configHome 'bookmarks.json'
            Test-Path -LiteralPath $path | Should -BeTrue
            $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
            $stored.version | Should -Be 1
            $savedBookmark = @($stored.bookmarks | Where-Object Name -EQ 'demo-bookmark')
            $savedBookmark.Count | Should -Be 1
            $savedBookmark[0].Context | Should -Be 'demo-context'
            $savedBookmark[0].Namespace | Should -Be 'demo'

            Remove-KubeBookmark demo-bookmark -Confirm:$false
            $storedAfterDelete = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
            @($storedAfterDelete.bookmarks | Where-Object Name -EQ 'demo-bookmark').Count | Should -Be 0
        }
        finally {
            $env:KUBESHELL_CONFIG_HOME = $previous
        }
    }
}

Describe 'KubeShell CRD schema model' {
    BeforeAll {
        $noEnum = [string[]]@()
        $noChildren = [KubeShell.Runtime.KubeSchemaField[]]@()
        $nameField = [KubeShell.Runtime.KubeSchemaField]::new('name', 'metadata.name', 'string', $null, 'Object name.', $false, $noEnum, $noChildren)
        $metadataField = [KubeShell.Runtime.KubeSchemaField]::new('metadata', 'metadata', 'object', $null, 'Standard metadata.', $false, $noEnum, [KubeShell.Runtime.KubeSchemaField[]]@($nameField))
        $replicasField = [KubeShell.Runtime.KubeSchemaField]::new('replicas', 'spec.replicas', 'integer', 'int32', 'Desired replicas.', $false, $noEnum, $noChildren)
        $imageField = [KubeShell.Runtime.KubeSchemaField]::new('image', 'spec.template.image', 'string', $null, 'Container image.', $false, $noEnum, $noChildren)
        $templateField = [KubeShell.Runtime.KubeSchemaField]::new('template', 'spec.template', 'object', $null, 'Template.', $false, $noEnum, [KubeShell.Runtime.KubeSchemaField[]]@($imageField))
        $specField = [KubeShell.Runtime.KubeSchemaField]::new('spec', 'spec', 'object', $null, 'Widget spec.', $true, $noEnum, [KubeShell.Runtime.KubeSchemaField[]]@($replicasField, $templateField))
        $global:KubeShellSchemaFixture = [KubeShell.Runtime.KubeSchemaDocument]::new(
            [KubeShell.Runtime.GroupVersionResource]::new('example.io', 'v1', 'widgets'),
            'Widget',
            $null,
            'object',
            $null,
            'Widget resource.',
            [KubeShell.Runtime.KubeSchemaField[]]@($metadataField, $specField)
        )
    }

    AfterAll {
        Remove-Variable KubeShellSchemaFixture -Scope Global -ErrorAction SilentlyContinue
    }

    It 'projects the typed OpenAPI schema tree into dotted field paths' {
        Mock Invoke-KubeRuntimeSchema -ModuleName KubeShell.Resources {
            $global:KubeShellSchemaFixture
        }

        $fields = @(Get-KubeSchemaField widget -ApiVersion example.io/v1)

        $fields.Path | Should -Contain 'metadata.name'
        $fields.Path | Should -Contain 'spec.replicas'
        $fields.Path | Should -Contain 'spec.template.image'
        ($fields | Where-Object Path -EQ 'spec.template.image').Type | Should -Be 'string'

        Should -Invoke Invoke-KubeRuntimeSchema -ModuleName KubeShell.Resources -Times 1 -Exactly -ParameterFilter {
            $Resource -eq 'widget' -and $ApiVersion -eq 'example.io/v1' -and $Recursive
        }
    }
}

Describe 'KubeShell managed YAML conversion' {
    It 'parses multi-document Kubernetes YAML without invoking kubectl' {
        $yaml = @'
apiVersion: v1
kind: ConfigMap
metadata:
  name: first
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: second
'@
        $documents = @($yaml | ConvertFrom-KubeYaml)
        $documents.Count | Should -Be 2
        $documents[0].metadata.name | Should -Be 'first'
        $documents[1].metadata.name | Should -Be 'second'
    }

    It 'round-trips string scalars that resemble YAML booleans or numbers' {
        $source = [pscustomobject]@{
            apiVersion = 'v1'
            kind = 'ConfigMap'
            metadata = [pscustomobject]@{ name = 'scalar-test' }
            data = [pscustomobject]@{ enabled = 'yes'; code = '0123'; literal = 'null' }
        }

        $yaml = $source | ConvertTo-KubeYaml
        $roundTrip = $yaml | ConvertFrom-KubeYaml
        $roundTrip.data.enabled | Should -BeExactly 'yes'
        $roundTrip.data.code | Should -BeExactly '0123'
        $roundTrip.data.literal | Should -BeExactly 'null'
    }
}
