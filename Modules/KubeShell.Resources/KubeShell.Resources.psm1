Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Core/KubeShell.Core.psd1') -Scope Local

function Get-KubeResource {
    [CmdletBinding(DefaultParameterSetName = 'CurrentNamespace')]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Resource,
        [Parameter(Position = 1)] [string] $Name,
        [Parameter(ParameterSetName = 'Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName = 'AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector,
        [Alias('Field')] [string] $FieldSelector
    )

    Invoke-KubeTypedGet -Resource $Resource -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector -FieldSelector $FieldSelector
}

function New-KubeTypedGetParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [string] $Name,
        [string] $Namespace,
        [switch] $AllNamespaces,
        [string] $LabelSelector,
        [string] $FieldSelector
    )

    $parameters = @{ Resource = $Resource }
    if ($Name) { $parameters.Name = $Name }
    if ($Namespace) { $parameters.Namespace = $Namespace }
    if ($AllNamespaces) { $parameters.AllNamespaces = $true }
    if ($LabelSelector) { $parameters.LabelSelector = $LabelSelector }
    if ($FieldSelector) { $parameters.FieldSelector = $FieldSelector }
    return $parameters
}

function Get-KubePod {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector,
        [Alias('Field')] [string] $FieldSelector,
        [string] $Node
    )
    if ($Node) {
        $nodeSelector = "spec.nodeName=$Node"
        $FieldSelector = if ($FieldSelector) { "$FieldSelector,$nodeSelector" } else { $nodeSelector }
    }
    $p = New-KubeTypedGetParameters -Resource 'pod' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector -FieldSelector $FieldSelector
    Get-KubeResource @p
}

function Get-KubeDeployment {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'deployment' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeStatefulSet {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'statefulset' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeDaemonSet {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'daemonset' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeReplicaSet {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'replicaset' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeJob {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'job' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeCronJob {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'cronjob' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeService {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'service' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeIngress {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'ingress' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeConfigMap {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'configmap' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeSecret {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'secret' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeSecretValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Secret,
        [Parameter(Mandatory, Position=1)] [string] $Key,
        [string] $Namespace,
        [switch] $AsBytes
    )

    process {
        $identity = Resolve-KubeIdentity $Secret $Namespace 'Secret'
        $secretObject = if ($Secret -is [string]) { Get-KubeSecret $identity.Name -Namespace $identity.Namespace } else { $Secret }
        $data = Get-KubePropertyValue $secretObject @('data')
        if (-not $data -or -not $data.PSObject.Properties[$Key]) {
            throw "Secret '$($identity.Name)' has no key '$Key'."
        }

        $bytes = [Convert]::FromBase64String([string]$data.PSObject.Properties[$Key].Value)
        if ($AsBytes) { return ,$bytes }
        return [Text.Encoding]::UTF8.GetString($bytes)
    }
}

function Get-KubeNode {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Alias('Label')] [string] $LabelSelector,
        [Alias('Field')] [string] $FieldSelector
    )
    Get-KubeResource node $Name -LabelSelector $LabelSelector -FieldSelector $FieldSelector
}

function Get-KubeNamespace {
    [CmdletBinding()]
    param([Parameter(Position=0)] [string] $Name, [Alias('Label')] [string] $LabelSelector)
    Get-KubeResource namespace $Name -LabelSelector $LabelSelector
}

function Get-KubePersistentVolumeClaim {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'persistentvolumeclaim' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubePersistentVolume {
    [CmdletBinding()]
    param([Parameter(Position=0)] [string] $Name, [Alias('Label')] [string] $LabelSelector)
    Get-KubeResource persistentvolume $Name -LabelSelector $LabelSelector
}

function Get-KubeStorageClass {
    [CmdletBinding()]
    param([Parameter(Position=0)] [string] $Name, [Alias('Label')] [string] $LabelSelector)
    Get-KubeResource storageclass $Name -LabelSelector $LabelSelector
}

function Get-KubeEndpointSlice {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector
    )
    $p = New-KubeTypedGetParameters -Resource 'endpointslice' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces -LabelSelector $LabelSelector
    Get-KubeResource @p
}

function Get-KubeRole {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param([string]$Name,[Parameter(ParameterSetName='Namespace')][string]$Namespace,[Parameter(ParameterSetName='AllNamespaces')][switch]$AllNamespaces)
    $p = New-KubeTypedGetParameters -Resource 'role' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces
    Get-KubeResource @p
}

function Get-KubeRoleBinding {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param([string]$Name,[Parameter(ParameterSetName='Namespace')][string]$Namespace,[Parameter(ParameterSetName='AllNamespaces')][switch]$AllNamespaces)
    $p = New-KubeTypedGetParameters -Resource 'rolebinding' -Name $Name -Namespace $Namespace -AllNamespaces:$AllNamespaces
    Get-KubeResource @p
}

function Get-KubeClusterRole {
    [CmdletBinding()]
    param([string]$Name)
    Get-KubeResource clusterrole $Name
}

function Get-KubeClusterRoleBinding {
    [CmdletBinding()]
    param([string]$Name)
    Get-KubeResource clusterrolebinding $Name
}

function Get-KubeEvent {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Field')] [string] $FieldSelector
    )

    $p = New-KubeTypedGetParameters -Resource 'event' -Namespace $Namespace -AllNamespaces:$AllNamespaces -FieldSelector $FieldSelector
    Get-KubeResource @p | Sort-Object -Descending {
        (Get-KubePropertyValue $_ @('lastTimestamp')) ??
        (Get-KubePropertyValue $_ @('eventTime')) ??
        (Get-KubePropertyValue $_ @('metadata','creationTimestamp'))
    }
}

function Get-KubeContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Pod,
        [string] $Namespace
    )
    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $podObject = if ($Pod -is [string]) { Get-KubePod $identity.Name -Namespace $identity.Namespace } else { $Pod }
        foreach ($container in @(Get-KubePropertyValue $podObject @('spec','containers'))) {
            if ($null -eq $container) { continue }
            [pscustomobject]@{
                PSTypeName = 'KubeShell.Container'
                Name       = [string](Get-KubePropertyValue $container @('name'))
                Image      = [string](Get-KubePropertyValue $container @('image'))
                Pod        = $identity.Name
                Namespace  = $identity.Namespace
                Spec       = $container
            }
        }
    }
}

function Get-KubeKind {
    [CmdletBinding()]
    param([string] $Name, [switch] $Refresh)

    foreach ($descriptor in @(Invoke-KubeRuntimePreferredResources -Refresh:$Refresh)) {
        if (-not $descriptor.Verbs.Contains('list')) { continue }
        $item = [pscustomobject]@{
            PSTypeName = 'KubeShell.ApiResource'
            Name       = $descriptor.Gvr.Resource
            ShortNames = (@($descriptor.ShortNames) -join ',')
            ApiVersion = $descriptor.Gvr.ApiVersion
            Namespaced = $descriptor.Namespaced
            Kind       = $descriptor.Kind
            Gvr        = $descriptor.Gvr
            Verbs      = @($descriptor.Verbs)
            Categories = @($descriptor.Categories)
        }
        if (-not $Name -or $item.Name -like $Name -or $item.Kind -like $Name -or @($descriptor.ShortNames | Where-Object { $_ -like $Name }).Count -gt 0) {
            $item
        }
    }
}

function ConvertFrom-KubeSchemaField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)] [KubeShell.Runtime.KubeSchemaField] $Field,
        [string] $Resource,
        [string] $ApiVersion
    )

    process {
        [pscustomobject]@{
            PSTypeName  = 'KubeShell.SchemaField'
            Resource    = $Resource
            ApiVersion  = $ApiVersion
            Path        = $Field.Path
            Name        = $Field.Name
            Type        = $Field.Type
            Format      = $Field.Format
            Description = $Field.Description
            Required    = $Field.Required
            Enum        = @($Field.EnumValues)
            Depth       = if ([string]::IsNullOrWhiteSpace($Field.Path)) { 0 } else { ($Field.Path -split '\.').Count - 1 }
            Fields      = @($Field.Fields)
        }
    }
}

function Get-KubeSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Resource,
        [Parameter(Position=1)] [string] $Field,
        [string] $ApiVersion,
        [switch] $Recursive,
        [ValidateRange(0,64)] [int] $MaxDepth = 0
    )

    $schema = Invoke-KubeRuntimeSchema -Resource $Resource -Field $Field -ApiVersion $ApiVersion -Recursive:$Recursive -MaxDepth $MaxDepth
    [pscustomobject]@{
        PSTypeName  = 'KubeShell.Schema'
        Resource    = $schema.Gvr.Resource
        ApiVersion  = $schema.Gvr.ApiVersion
        Kind        = $schema.Kind
        Field       = $schema.FieldPath
        Type        = $schema.Type
        Format      = $schema.Format
        Description = $schema.Description
        Fields      = @($schema.Fields | ForEach-Object { ConvertFrom-KubeSchemaField -Field $_ -Resource $schema.Gvr.Resource -ApiVersion $schema.Gvr.ApiVersion })
    }
}

function Get-KubeSchemaField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Resource,
        [string] $ApiVersion
    )

    $schema = Invoke-KubeRuntimeSchema -Resource $Resource -ApiVersion $ApiVersion -Recursive
    $stack = [Collections.Generic.Stack[KubeShell.Runtime.KubeSchemaField]]::new()
    for ($i = $schema.Fields.Count - 1; $i -ge 0; $i--) { $stack.Push($schema.Fields[$i]) }
    while ($stack.Count -gt 0) {
        $field = $stack.Pop()
        ConvertFrom-KubeSchemaField -Field $field -Resource $schema.Gvr.Resource -ApiVersion $schema.Gvr.ApiVersion
        for ($i = $field.Fields.Count - 1; $i -ge 0; $i--) { $stack.Push($field.Fields[$i]) }
    }
}

function Watch-KubeResource {
    [CmdletBinding(DefaultParameterSetName='CurrentNamespace')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Resource,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector,
        [Alias('Field')] [string] $FieldSelector
    )

    $query = [KubeShell.Runtime.ResourceQuery]::new(
        $Resource,
        $null,
        $Namespace,
        [bool]$AllNamespaces,
        $LabelSelector,
        $FieldSelector,
        $null
    )

    foreach ($event in Invoke-KubeRuntimeWatch -Query $query) {
        if ($null -ne $event.Error) {
            $message = [string]$event.Error.Message
            throw "Kubernetes watch failed: $message"
        }
        $object = if ($null -ne $event.Resource) { ConvertFrom-KubeRuntimeResource $event.Resource } else { $null }
        [pscustomobject]@{
            PSTypeName      = 'KubeShell.ResourceEvent'
            Type            = [string]$event.Type
            Kind            = if ($null -ne $object) { [string](Get-KubePropertyValue $object @('kind')) } else { $null }
            Namespace       = if ($null -ne $object) { [string](Get-KubePropertyValue $object @('Namespace')) } else { $null }
            Name            = if ($null -ne $object) { [string](Get-KubePropertyValue $object @('Name')) } else { $null }
            Object          = $object
            ResourceVersion = [string]$event.ResourceVersion
            Timestamp       = [datetimeoffset]::Now
        }
    }
}

Export-ModuleMember -Function @(
    'Get-KubeResource','Get-KubePod','Get-KubeDeployment','Get-KubeStatefulSet','Get-KubeDaemonSet','Get-KubeReplicaSet',
    'Get-KubeJob','Get-KubeCronJob','Get-KubeService','Get-KubeIngress','Get-KubeConfigMap','Get-KubeSecret','Get-KubeSecretValue',
    'Get-KubeNode','Get-KubeNamespace','Get-KubePersistentVolumeClaim','Get-KubePersistentVolume','Get-KubeStorageClass','Get-KubeEndpointSlice',
    'Get-KubeRole','Get-KubeRoleBinding','Get-KubeClusterRole','Get-KubeClusterRoleBinding','Get-KubeEvent','Get-KubeContainer','Get-KubeKind','Get-KubeSchema','Get-KubeSchemaField','Watch-KubeResource'
)
