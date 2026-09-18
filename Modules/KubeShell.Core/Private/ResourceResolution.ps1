# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Add-KubeNamespaceArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Collections.Generic.List[string]] $Arguments,
        [string] $Namespace,
        [switch] $AllNamespaces
    )

    if ($AllNamespaces) {
        [void]$Arguments.Add('--all-namespaces')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Namespace)) {
        [void]$Arguments.Add('--namespace')
        [void]$Arguments.Add($Namespace)
    }
}
function Add-KubeSelectorArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Collections.Generic.List[string]] $Arguments,
        [string] $LabelSelector,
        [string] $FieldSelector
    )

    if ($LabelSelector) {
        [void]$Arguments.Add('--selector')
        [void]$Arguments.Add($LabelSelector)
    }
    if ($FieldSelector) {
        [void]$Arguments.Add('--field-selector')
        [void]$Arguments.Add($FieldSelector)
    }
}
function Add-KubeDryRunArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Collections.Generic.List[string]] $Arguments,
        [ValidateSet('None', 'Client', 'Server')] [string] $DryRun = 'None'
    )

    if ($DryRun -ne 'None') {
        [void]$Arguments.Add("--dry-run=$($DryRun.ToLowerInvariant())")
    }
}
function Resolve-KubeIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [string] $Namespace,
        [string] $Kind
    )

    if ($InputObject -is [string]) {
        return [pscustomobject]@{
            Name      = [string]$InputObject
            Namespace = $Namespace
            Kind      = $Kind
        }
    }

    $name = (Get-KubePropertyValue $InputObject @('Name')) ?? (Get-KubePropertyValue $InputObject @('metadata','name'))
    if (-not $name) { throw 'Could not determine Kubernetes resource name from pipeline input.' }

    $resolvedNamespace = if ($Namespace) { $Namespace } else { (Get-KubePropertyValue $InputObject @('Namespace')) ?? (Get-KubePropertyValue $InputObject @('metadata','namespace')) }
    $resolvedKind = if ($Kind) { $Kind } else { Get-KubePropertyValue $InputObject @('kind') }

    [pscustomobject]@{
        Name      = [string]$name
        Namespace = [string]$resolvedNamespace
        Kind      = [string]$resolvedKind
    }
}
function Resolve-KubeResourceName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Kind)

    $map = @{
        Pod='pod'; Deployment='deployment'; StatefulSet='statefulset'; DaemonSet='daemonset'
        ReplicaSet='replicaset'; Service='service'; Ingress='ingress'; ConfigMap='configmap'
        Secret='secret'; Job='job'; CronJob='cronjob'; Node='node'; Namespace='namespace'
        PersistentVolumeClaim='persistentvolumeclaim'; PersistentVolume='persistentvolume'
        StorageClass='storageclass'; EndpointSlice='endpointslice'; Role='role'; RoleBinding='rolebinding'
        ClusterRole='clusterrole'; ClusterRoleBinding='clusterrolebinding'
    }

    if ($map.ContainsKey($Kind)) { return $map[$Kind] }
    return $Kind.ToLowerInvariant()
}
function Invoke-KubeTypedGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [string] $Name,
        [string] $Namespace,
        [switch] $AllNamespaces,
        [string] $LabelSelector,
        [string] $FieldSelector,
        [string] $ApiVersion
    )

    $query = [KubeShell.Runtime.ResourceQuery]::new(
        $Resource,
        $Name,
        $Namespace,
        [bool]$AllNamespaces,
        $LabelSelector,
        $FieldSelector,
        $ApiVersion
    )

    foreach ($runtimeResource in @(Invoke-KubeRuntimeGet -Query $query)) {
        ConvertFrom-KubeRuntimeResource $runtimeResource
    }
}
