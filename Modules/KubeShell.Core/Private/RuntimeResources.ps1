# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Invoke-KubeRuntimeGet {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [KubeShell.Runtime.ResourceQuery] $Query)

    try {
        $client = New-KubeRuntimeResourceClient
        return $client.Get((Get-KubeRuntimeTarget), $Query, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Query)
    }
}

function Invoke-KubeRuntimeApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [string] $PayloadJson,
        [KubeShell.Runtime.KubeApplyOptions] $Options
    )

    try {
        $client = New-KubeRuntimeResourceClient
        return $client.Apply((Get-KubeRuntimeTarget), $Identity, $PayloadJson, $Options, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimePatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [string] $PayloadJson,
        [KubeShell.Runtime.KubePatchOptions] $Options
    )

    try {
        $client = New-KubeRuntimeResourceClient
        return $client.Patch((Get-KubeRuntimeTarget), $Identity, $PayloadJson, $Options, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimeDelete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [KubeShell.Runtime.KubeDeleteOptions] $Options
    )

    try {
        $client = New-KubeRuntimeResourceClient
        $client.Delete((Get-KubeRuntimeTarget), $Identity, $Options, (Get-KubeRuntimeExecutionContext))
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity)
    }
}

function Invoke-KubeRuntimeWatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [KubeShell.Runtime.ResourceQuery] $Query)

    try {
        $client = New-KubeRuntimeWatchClient
        $operation = [KubeShell.Runtime.KubeWatchOperation]::new($Query)
        foreach ($event in $client.Watch((Get-KubeRuntimeTarget), $operation, (Get-KubeRuntimeExecutionContext))) {
            $event
        }
    }
    catch [KubeShell.Runtime.KubeException] {
        throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Query)
    }
}

function New-KubeChangeResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Apply','Patch','Delete')] [string] $Operation,
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [ValidateSet('None','Client','Server')] [string] $DryRun = 'None'
    )

    [pscustomobject]@{
        PSTypeName = 'KubeShell.ChangeResult'
        Operation  = $Operation
        Resource   = $Identity.Resource
        Name       = $Identity.Name
        Namespace  = $Identity.Namespace
        ApiVersion = $Identity.ApiVersion
        DryRun     = $DryRun
        Succeeded  = $true
    }
}

function ConvertFrom-KubeRuntimeResource {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $Resource)

    process {
        $json = if ($Resource -is [string]) { [string]$Resource } else { [string]$Resource.RawJson }
        if ([string]::IsNullOrWhiteSpace($json)) { return }
        ConvertTo-KubeObject ($json | ConvertFrom-Json -Depth 100)
    }
}
