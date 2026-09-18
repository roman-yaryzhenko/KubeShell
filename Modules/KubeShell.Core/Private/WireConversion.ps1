# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function ConvertTo-KubeWireObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [psobject] $InputObject,
        [switch] $ForApply
    )

    process {
        # Presentation cleanup is intentionally PowerShell-owned. Runtime only strips
        # Kubernetes API-server-owned wire fields after this adapter has removed PSType data.
        $wireProperties = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($script:KubeShellEnrichmentProperties -ccontains $property.Name) { continue }
            $wireProperties[$property.Name] = $property.Value
        }

        $json = [pscustomobject]$wireProperties | ConvertTo-Json -Depth 100 -Compress
        if ($ForApply) {
            $json = [KubeShell.Runtime.KubeWireSerializer]::PrepareApplyJson($json)
        }
        return $json | ConvertFrom-Json -Depth 100
    }
}
function ConvertTo-KubeWireJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [psobject] $InputObject,
        [switch] $ForApply,
        [switch] $Compress
    )

    process {
        $wireObject = ConvertTo-KubeWireObject -InputObject $InputObject -ForApply:$ForApply
        return $wireObject | ConvertTo-Json -Depth 100 -Compress:$Compress
    }
}
