Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Core/KubeShell.Core.psd1') -Scope Local

$serializationRoot = Join-Path $PSScriptRoot '../../Libraries/KubeShell.Serialization'
$serializationOutput = Join-Path $serializationRoot 'bin/Release/net8.0'
$serializationDll = Join-Path $serializationOutput 'KubeShell.Serialization.dll'
$yamlDotNetDll = Join-Path $serializationOutput 'YamlDotNet.dll'
if (-not ('KubeShell.Serialization.KubeYamlSerializer' -as [type])) {
    if (-not (Test-Path -LiteralPath $serializationDll -PathType Leaf)) {
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            throw 'KubeShell managed YAML support is not built. Install the packaged module or build Libraries/KubeShell.Serialization with .NET 8+.'
        }
        $serializationDll = & (Join-Path $serializationRoot 'build.ps1') | Select-Object -Last 1
        $serializationOutput = Split-Path -Parent $serializationDll
        $yamlDotNetDll = Join-Path $serializationOutput 'YamlDotNet.dll'
    }
    if (-not ('YamlDotNet.YamlStream' -as [type])) { Add-Type -Path $yamlDotNetDll }
    Add-Type -Path $serializationDll
}

function Get-KubeManifestJsonDocuments {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,ParameterSetName='Path')] [string] $Path,
        [Parameter(Mandatory,ParameterSetName='Text')] [string] $Text,
        [Parameter(Mandatory,ParameterSetName='Object')] $InputObject
    )

    if ($PSCmdlet.ParameterSetName -eq 'Object') {
        return ,(ConvertTo-KubeWireJson -InputObject $InputObject -ForApply -Compress)
    }
    $content = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } else { $Text }
    return @([KubeShell.Serialization.KubeYamlSerializer]::ToJsonDocuments([string]$content) | Where-Object { $_ -and $_ -ne 'null' })
}

function Resolve-KubeManifestIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Json,
        [string] $Namespace
    )

    $object = $Json | ConvertFrom-Json -Depth 100
    $kind = [string](Get-KubePropertyValue $object @('kind'))
    $apiVersion = [string](Get-KubePropertyValue $object @('apiVersion'))
    $name = [string](Get-KubePropertyValue $object @('metadata','name'))
    $documentNamespace = [string](Get-KubePropertyValue $object @('metadata','namespace'))
    if ([string]::IsNullOrWhiteSpace($kind) -or [string]::IsNullOrWhiteSpace($apiVersion) -or [string]::IsNullOrWhiteSpace($name)) {
        throw 'Each manifest document must contain apiVersion, kind and metadata.name.'
    }
    $descriptor = Invoke-KubeRuntimeResolveResource -Resource $kind -ApiVersion $apiVersion
    if ($null -eq $descriptor) { throw "Discovery could not resolve manifest resource $apiVersion/$kind." }
    $scope = if (-not $descriptor.Namespaced) {
        [KubeShell.Runtime.KubeNamespaceScope]::Cluster
    } elseif (-not [string]::IsNullOrWhiteSpace($Namespace)) {
        [KubeShell.Runtime.KubeNamespaceScope]::Explicit($Namespace)
    } elseif (-not [string]::IsNullOrWhiteSpace($documentNamespace)) {
        [KubeShell.Runtime.KubeNamespaceScope]::Explicit($documentNamespace)
    } else {
        [KubeShell.Runtime.KubeNamespaceScope]::Default
    }
    return [KubeShell.Runtime.ResourceIdentity]::new($descriptor.Gvr, $name, $scope, $null, $kind)
}

function Get-KubeManifestDocumentsFromParameters {
    [CmdletBinding()]
    param([string] $ParameterSetName, [string] $Path, [string] $Text, $InputObject, [string] $Namespace)
    $jsons = switch ($ParameterSetName) {
        'Path' { Get-KubeManifestJsonDocuments -Path $Path }
        'Text' { Get-KubeManifestJsonDocuments -Text $Text }
        'Object' { Get-KubeManifestJsonDocuments -InputObject $InputObject }
    }
    foreach ($json in @($jsons)) {
        [pscustomobject]@{ Json = [string]$json; Identity = Resolve-KubeManifestIdentity -Json ([string]$json) -Namespace $Namespace }
    }
}

function Set-KubeManifest {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium', DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,Position=0,ParameterSetName='Path')] [string] $Path,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Text')] [string] $Text,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Object')] $InputObject,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None',
        [switch] $ServerSide,
        [string] $FieldManager,
        [switch] $ForceConflicts
    )
    process {
        $documents = @(Get-KubeManifestDocumentsFromParameters $PSCmdlet.ParameterSetName $Path $Text $InputObject $Namespace)
        foreach ($document in $documents) {
            $identity = $document.Identity
            if (-not $PSCmdlet.ShouldProcess("$($identity.Gvr)/$($identity.Name)", 'Apply Kubernetes manifest document')) { continue }
            $options = [KubeShell.Runtime.KubeApplyOptions]::new(
                (ConvertTo-KubeRuntimeDryRunMode $DryRun), [bool]$ServerSide, $FieldManager, [bool]$ForceConflicts)
            $resource = Invoke-KubeRuntimeApply -Identity $identity -PayloadJson $document.Json -Options $options
            if ($null -ne $resource) { ConvertFrom-KubeRuntimeResource $resource }
        }
    }
}

function Test-KubeManifest {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,Position=0,ParameterSetName='Path')] [string] $Path,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Text')] [string] $Text,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Object')] $InputObject,
        [string] $Namespace,
        [ValidateSet('Client','Server')] [string] $Mode='Server'
    )
    process {
        foreach ($document in @(Get-KubeManifestDocumentsFromParameters $PSCmdlet.ParameterSetName $Path $Text $InputObject $Namespace)) {
            $options = [KubeShell.Runtime.KubeApplyOptions]::new(
                [KubeShell.Runtime.KubeApplyStrategy]::ClientSide,
                [KubeShell.Runtime.KubePreviewMode]([Enum]::Parse([KubeShell.Runtime.KubePreviewMode], $Mode, $true)),
                'KubeShell', $false)
            $resource = Invoke-KubeRuntimeApply -Identity $document.Identity -PayloadJson $document.Json -Options $options
            if ($null -ne $resource) { ConvertFrom-KubeRuntimeResource $resource }
        }
    }
}

function Compare-KubeManifest {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,Position=0,ParameterSetName='Path')] [string] $Path,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Text')] [string] $Text,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Object')] $InputObject,
        [string] $Namespace,
        [switch] $ServerSide,
        [string] $FieldManager
    )
    process {
        foreach ($document in @(Get-KubeManifestDocumentsFromParameters $PSCmdlet.ParameterSetName $Path $Text $InputObject $Namespace)) {
            $identity = $document.Identity
            $liveJson = 'null'
            try {
                $query = [KubeShell.Runtime.ResourceQuery]::new($identity.Gvr, $identity.Name, $identity.NamespaceScope)
                $live = @(Invoke-KubeRuntimeGet -Query $query) | Select-Object -First 1
                if ($null -ne $live) { $liveJson = ConvertTo-KubeWireJson -InputObject ($live.RawJson | ConvertFrom-Json -Depth 100) -ForApply -Compress }
            }
            catch {
                $kubeException = if ($_.Exception -is [KubeShell.Runtime.KubeException]) { $_.Exception } elseif ($_.Exception.InnerException -is [KubeShell.Runtime.KubeException]) { $_.Exception.InnerException } else { $null }
                if ($null -eq $kubeException -or $kubeException.Kind -ne [KubeShell.Runtime.KubeErrorKind]::NotFound) { throw }
            }

            $strategy = if ($ServerSide) { [KubeShell.Runtime.KubeApplyStrategy]::ServerSide } else { [KubeShell.Runtime.KubeApplyStrategy]::ClientSide }
            $options = [KubeShell.Runtime.KubeApplyOptions]::new($strategy, [KubeShell.Runtime.KubePreviewMode]::Server, $FieldManager, $false)
            $merged = Invoke-KubeRuntimeApply -Identity $identity -PayloadJson $document.Json -Options $options
            $mergedJson = if ($null -eq $merged) { $document.Json } else { ConvertTo-KubeWireJson -InputObject ($merged.RawJson | ConvertFrom-Json -Depth 100) -ForApply -Compress }
            $canonicalLive = if ($liveJson -eq 'null') { 'null' } else { [KubeShell.Serialization.KubeYamlSerializer]::CanonicalizeJson($liveJson) }
            $canonicalMerged = [KubeShell.Serialization.KubeYamlSerializer]::CanonicalizeJson($mergedJson)
            $different = $canonicalLive -ne $canonicalMerged
            $liveYaml = if ($canonicalLive -eq 'null') { '' } else { [KubeShell.Serialization.KubeYamlSerializer]::ToYaml($canonicalLive) }
            $mergedYaml = [KubeShell.Serialization.KubeYamlSerializer]::ToYaml($canonicalMerged)
            [pscustomobject]@{
                PSTypeName = 'KubeShell.ManifestDiff'
                Different  = $different
                Resource   = $identity.Gvr.ToString()
                Name       = $identity.Name
                Diff       = if ($different) { [KubeShell.Serialization.KubeTextDiff]::Unified($liveYaml, $mergedYaml, "live/$($identity.Name)", "merged/$($identity.Name)") } else { '' }
            }
        }
    }
}

function Remove-KubeManifest {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High', DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,Position=0,ParameterSetName='Path')] [string] $Path,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Text')] [string] $Text,
        [Parameter(Mandatory,ValueFromPipeline,ParameterSetName='Object')] $InputObject,
        [string] $Namespace,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None'
    )
    process {
        foreach ($document in @(Get-KubeManifestDocumentsFromParameters $PSCmdlet.ParameterSetName $Path $Text $InputObject $Namespace)) {
            $identity = $document.Identity
            if (-not $PSCmdlet.ShouldProcess("$($identity.Gvr)/$($identity.Name)", 'Delete resource described by manifest')) { continue }
            if ($DryRun -eq 'Client') {
                New-KubeChangeResult -Operation Delete -Identity $identity -DryRun Client
                continue
            }
            $options = [KubeShell.Runtime.KubeDeleteOptions]::new((ConvertTo-KubeRuntimeDryRunMode $DryRun), $false, $null)
            Invoke-KubeRuntimeDelete -Identity $identity -Options $options
            New-KubeChangeResult -Operation Delete -Identity $identity -DryRun $DryRun
        }
    }
}

function Set-KubeResourcePatch {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Resource,
        [Parameter(Mandatory,Position=1)] [string] $Name,
        [Parameter(Mandatory)] $Patch,
        [string] $Namespace,
        [ValidateSet('Merge','Json','Strategic')] [string] $Type='Merge',
        [ValidateSet('None','Client','Server')] [string] $DryRun='None',
        [string] $ApiVersion
    )

    $target = "$Resource/$Name"
    if (-not $PSCmdlet.ShouldProcess("$Namespace/$target", "Patch resource ($Type)")) { return }

    $json = if ($Patch -is [string]) { [string]$Patch } else { $Patch | ConvertTo-Json -Depth 100 -Compress }
    $patchType = [KubeShell.Runtime.KubePatchType]([Enum]::Parse([KubeShell.Runtime.KubePatchType], $Type, $true))
    $options = [KubeShell.Runtime.KubePatchOptions]::new($patchType, (ConvertTo-KubeRuntimeDryRunMode $DryRun))
    $identity = [KubeShell.Runtime.ResourceIdentity]::new($Resource, $Name, $Namespace, $null, $ApiVersion)
    $runtimeResource = Invoke-KubeRuntimePatch -Identity $identity -PayloadJson $json -Options $options
    ConvertFrom-KubeRuntimeResource $runtimeResource
}

function Set-KubeObject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory,ValueFromPipeline)] $InputObject,
        [ValidateSet('None','Client','Server')] [string] $DryRun='None',
        [switch] $ServerSide,
        [string] $FieldManager
    )
    process {
        $name = [string]((Get-KubePropertyValue $InputObject @('metadata','name')) ?? (Get-KubePropertyValue $InputObject @('Name')))
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Could not determine Kubernetes resource name from object.' }

        $kind = [string]((Get-KubePropertyValue $InputObject @('kind')) ?? 'resource')
        $resource = Resolve-KubeResourceName $kind
        $namespace = [string]((Get-KubePropertyValue $InputObject @('metadata','namespace')) ?? (Get-KubePropertyValue $InputObject @('Namespace')))
        $apiVersion = [string](Get-KubePropertyValue $InputObject @('apiVersion'))
        if (-not $PSCmdlet.ShouldProcess("$kind/$name", 'Apply Kubernetes object')) { return }

        $wireJson = ConvertTo-KubeWireJson -InputObject $InputObject -ForApply -Compress
        $identity = [KubeShell.Runtime.ResourceIdentity]::new($resource, $name, $namespace, $kind, $apiVersion)
        $options = [KubeShell.Runtime.KubeApplyOptions]::new(
            (ConvertTo-KubeRuntimeDryRunMode $DryRun),
            [bool]$ServerSide,
            $FieldManager,
            $false
        )
        $runtimeResource = Invoke-KubeRuntimeApply -Identity $identity -PayloadJson $wireJson -Options $options
        ConvertFrom-KubeRuntimeResource $runtimeResource
    }
}

function Get-KubeYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Resource,
        [Parameter(Mandatory,Position=1)] [string] $Name,
        [string] $Namespace,
        [string] $ApiVersion
    )

    $query = [KubeShell.Runtime.ResourceQuery]::new($Resource, $Name, $Namespace, $false, $null, $null, $ApiVersion)
    $runtimeResource = @(Invoke-KubeRuntimeGet -Query $query) | Select-Object -First 1
    if ($null -eq $runtimeResource) { return }
    [KubeShell.Serialization.KubeYamlSerializer]::ToYaml([string]$runtimeResource.RawJson)
}

function Get-KubeJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Resource,
        [Parameter(Mandatory,Position=1)] [string] $Name,
        [string] $Namespace,
        [string] $ApiVersion
    )

    $query = [KubeShell.Runtime.ResourceQuery]::new($Resource, $Name, $Namespace, $false, $null, $null, $ApiVersion)
    $runtimeResource = @(Invoke-KubeRuntimeGet -Query $query) | Select-Object -First 1
    if ($null -ne $runtimeResource) { [string]$runtimeResource.RawJson }
}

function ConvertFrom-KubeYaml {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] [string] $Yaml)
    process {
        foreach ($json in [KubeShell.Serialization.KubeYamlSerializer]::ToJsonDocuments($Yaml)) {
            if ($json -eq 'null') { continue }
            $json | ConvertFrom-Json -Depth 100
        }
    }
}

function ConvertTo-KubeYaml {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $InputObject)
    process {
        $json = ConvertTo-KubeWireJson -InputObject $InputObject
        [KubeShell.Serialization.KubeYamlSerializer]::ToYaml($json)
    }
}

Export-ModuleMember -Function @(
    'Set-KubeManifest','Test-KubeManifest','Compare-KubeManifest','Remove-KubeManifest','Set-KubeResourcePatch','Set-KubeObject',
    'Get-KubeYaml','Get-KubeJson','ConvertFrom-KubeYaml','ConvertTo-KubeYaml'
)
