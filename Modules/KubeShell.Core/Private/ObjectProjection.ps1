# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Get-KubePropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string[]] $Path
    )

    $current = $InputObject
    foreach ($segment in $Path) {
        if ($null -eq $current) { return $null }
        if ($current -is [Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $current = $property.Value
    }
    return $current
}
function Add-KubeNoteProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] $Value
    )

    if (-not $InputObject.PSObject.Properties[$Name]) {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}
function Format-KubeAge {
    [CmdletBinding()]
    param([AllowNull()] [timespan] $Age)

    if ($null -eq $Age) { return $null }
    if ($Age.TotalDays -ge 1) { return '{0}d{1}h' -f [math]::Floor($Age.TotalDays), $Age.Hours }
    if ($Age.TotalHours -ge 1) { return '{0}h{1}m' -f [math]::Floor($Age.TotalHours), $Age.Minutes }
    if ($Age.TotalMinutes -ge 1) { return '{0}m{1}s' -f [math]::Floor($Age.TotalMinutes), $Age.Seconds }
    return '{0}s' -f [math]::Max(0, [math]::Floor($Age.TotalSeconds))
}
function ConvertFrom-KubeCpuQuantity {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 0.0 }
    if ($Value -match '^([0-9]+(?:\.[0-9]+)?)m$') { return [double]$Matches[1] / 1000.0 }
    if ($Value -match '^([0-9]+(?:\.[0-9]+)?)u$') { return [double]$Matches[1] / 1000000.0 }
    if ($Value -match '^([0-9]+(?:\.[0-9]+)?)n$') { return [double]$Matches[1] / 1000000000.0 }
    return [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}
function ConvertFrom-KubeMemoryQuantity {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return [int64]0 }

    $binary = @{ Ki = 1KB; Mi = 1MB; Gi = 1GB; Ti = 1TB; Pi = 1PB }
    $decimal = @{ k = 1e3; M = 1e6; G = 1e9; T = 1e12; P = 1e15 }

    if ($Value -match '^([0-9]+(?:\.[0-9]+)?)(Ki|Mi|Gi|Ti|Pi)$') {
        return [int64]([double]$Matches[1] * $binary[$Matches[2]])
    }
    if ($Value -match '^([0-9]+(?:\.[0-9]+)?)(k|M|G|T|P)$') {
        return [int64]([double]$Matches[1] * $decimal[$Matches[2]])
    }
    if ($Value -match '^([0-9]+(?:\.[0-9]+)?)m$') {
        return [int64]([double]$Matches[1] / 1000.0)
    }

    return [int64][double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}
function Get-KubeReadyCondition {
    [CmdletBinding()]
    param([AllowNull()] $Conditions)

    if ($null -eq $Conditions) { return $null }
    return $Conditions | Where-Object type -EQ 'Ready' | Select-Object -First 1
}
function Add-KubeKindProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $InputObject,
        [Parameter(Mandatory)] [string] $Kind
    )

    switch ($Kind) {
        'Pod' {
            $statuses = @(Get-KubePropertyValue $InputObject @('status','containerStatuses'))
            if ($statuses.Count -eq 1 -and $null -eq $statuses[0]) { $statuses = @() }
            $containers = @(Get-KubePropertyValue $InputObject @('spec','containers'))
            if ($containers.Count -eq 1 -and $null -eq $containers[0]) { $containers = @() }
            $total = $containers.Count
            $readyCount = @($statuses | Where-Object { $_.PSObject.Properties['ready'] -and $_.ready }).Count
            $restarts = ($statuses | ForEach-Object { [int](Get-KubePropertyValue $_ @('restartCount')) } | Measure-Object -Sum).Sum
            if ($null -eq $restarts) { $restarts = 0 }
            $phase = Get-KubePropertyValue $InputObject @('status','phase')

            Add-KubeNoteProperty $InputObject Node (Get-KubePropertyValue $InputObject @('spec','nodeName'))
            Add-KubeNoteProperty $InputObject Phase $phase
            Add-KubeNoteProperty $InputObject Ready ("{0}/{1}" -f $readyCount, $total)
            Add-KubeNoteProperty $InputObject ReadyContainers $readyCount
            Add-KubeNoteProperty $InputObject TotalContainers $total
            Add-KubeNoteProperty $InputObject Restarts ([int]$restarts)
            Add-KubeNoteProperty $InputObject Images @($containers | ForEach-Object { Get-KubePropertyValue $_ @('image') })
            Add-KubeNoteProperty $InputObject Terminating ($null -ne (Get-KubePropertyValue $InputObject @('metadata','deletionTimestamp')))
            Add-KubeNoteProperty $InputObject Healthy (($phase -eq 'Running') -and ($total -gt 0) -and ($readyCount -eq $total))
        }
        'Deployment' {
            $desired = [int]((Get-KubePropertyValue $InputObject @('spec','replicas')) ?? 0)
            $ready = [int]((Get-KubePropertyValue $InputObject @('status','readyReplicas')) ?? 0)
            $available = [int]((Get-KubePropertyValue $InputObject @('status','availableReplicas')) ?? 0)
            $updated = [int]((Get-KubePropertyValue $InputObject @('status','updatedReplicas')) ?? 0)
            Add-KubeNoteProperty $InputObject Desired $desired
            Add-KubeNoteProperty $InputObject Ready ("{0}/{1}" -f $ready, $desired)
            Add-KubeNoteProperty $InputObject Available $available
            Add-KubeNoteProperty $InputObject Updated $updated
            Add-KubeNoteProperty $InputObject Healthy (($desired -eq $available) -and ($desired -eq $updated))
        }
        'StatefulSet' {
            $desired = [int]((Get-KubePropertyValue $InputObject @('spec','replicas')) ?? 0)
            $ready = [int]((Get-KubePropertyValue $InputObject @('status','readyReplicas')) ?? 0)
            Add-KubeNoteProperty $InputObject Desired $desired
            Add-KubeNoteProperty $InputObject Ready ("{0}/{1}" -f $ready, $desired)
            Add-KubeNoteProperty $InputObject Healthy ($desired -eq $ready)
        }
        'DaemonSet' {
            $desired = [int]((Get-KubePropertyValue $InputObject @('status','desiredNumberScheduled')) ?? 0)
            $ready = [int]((Get-KubePropertyValue $InputObject @('status','numberReady')) ?? 0)
            Add-KubeNoteProperty $InputObject Desired $desired
            Add-KubeNoteProperty $InputObject Ready ("{0}/{1}" -f $ready, $desired)
            Add-KubeNoteProperty $InputObject Healthy ($desired -eq $ready)
        }
        'Service' {
            Add-KubeNoteProperty $InputObject ServiceType (Get-KubePropertyValue $InputObject @('spec','type'))
            Add-KubeNoteProperty $InputObject ClusterIP (Get-KubePropertyValue $InputObject @('spec','clusterIP'))
            $ingress = @(Get-KubePropertyValue $InputObject @('status','loadBalancer','ingress'))
            if ($ingress.Count -eq 1 -and $null -eq $ingress[0]) { $ingress = @() }
            $external = @($ingress | ForEach-Object { (Get-KubePropertyValue $_ @('ip')) ?? (Get-KubePropertyValue $_ @('hostname')) }) -join ','
            Add-KubeNoteProperty $InputObject ExternalIP $external
            $servicePorts = @(Get-KubePropertyValue $InputObject @('spec','ports'))
            if ($servicePorts.Count -eq 1 -and $null -eq $servicePorts[0]) { $servicePorts = @() }
            $ports = @($servicePorts | ForEach-Object {
                $protocol = (Get-KubePropertyValue $_ @('protocol')) ?? 'TCP'
                "{0}:{1}/{2}" -f (Get-KubePropertyValue $_ @('port')), (Get-KubePropertyValue $_ @('targetPort')), $protocol
            }) -join ','
            Add-KubeNoteProperty $InputObject Ports $ports
        }
        'Node' {
            $conditions = Get-KubePropertyValue $InputObject @('status','conditions')
            $ready = Get-KubeReadyCondition $conditions
            $labels = Get-KubePropertyValue $InputObject @('metadata','labels')
            $roles = if ($labels) {
                @($labels.PSObject.Properties |
                    Where-Object Name -Like 'node-role.kubernetes.io/*' |
                    ForEach-Object { $_.Name.Substring('node-role.kubernetes.io/'.Length) })
            }
            else { @() }
            $readyStatus = Get-KubePropertyValue $ready @('status')
            $unschedulable = [bool]((Get-KubePropertyValue $InputObject @('spec','unschedulable')) ?? $false)
            Add-KubeNoteProperty $InputObject Ready ($readyStatus -eq 'True')
            Add-KubeNoteProperty $InputObject Roles ($roles -join ',')
            Add-KubeNoteProperty $InputObject Unschedulable $unschedulable
            Add-KubeNoteProperty $InputObject Healthy (($readyStatus -eq 'True') -and -not $unschedulable)
        }
        'Secret' {
            # Secret values remain accessible through .data, while the default table view exposes only keys.
            Add-KubeNoteProperty $InputObject SecretType (Get-KubePropertyValue $InputObject @('type'))
            $data = Get-KubePropertyValue $InputObject @('data')
            Add-KubeNoteProperty $InputObject DataKeys $(if ($data) { @($data.PSObject.Properties.Name) } else { @() })
        }
    }
}
function ConvertTo-KubeObject {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] [psobject] $InputObject)

    process {
        $kind = if ($InputObject.PSObject.Properties['kind'] -and $InputObject.kind) { [string]$InputObject.kind } else { 'Object' }
        $typeName = "KubeShell.$kind"
        if ($InputObject.PSObject.TypeNames[0] -ne $typeName) {
            $InputObject.PSObject.TypeNames.Insert(0, $typeName)
        }

        $metadata = Get-KubePropertyValue $InputObject @('metadata')
        if ($metadata) {
            Add-KubeNoteProperty $InputObject Name ([string](Get-KubePropertyValue $metadata @('name')))
            Add-KubeNoteProperty $InputObject Namespace ([string](Get-KubePropertyValue $metadata @('namespace')))

            $creationTimestamp = Get-KubePropertyValue $metadata @('creationTimestamp')
            if ($creationTimestamp) {
                try {
                    $age = [datetimeoffset]::Now - [datetimeoffset]$creationTimestamp
                    Add-KubeNoteProperty $InputObject Age $age
                    Add-KubeNoteProperty $InputObject AgeText (Format-KubeAge $age)
                }
                catch {
                    Write-Debug "Could not parse creationTimestamp '$creationTimestamp'."
                }
            }
        }

        Add-KubeKindProperties -InputObject $InputObject -Kind $kind
        return $InputObject
    }
}



$script:KubeShellEnrichmentProperties = @(
    'Name','Namespace','Age','AgeText',
    'Node','Phase','Ready','ReadyContainers','TotalContainers','Restarts','Images','Terminating','Healthy',
    'Desired','Available','Updated',
    'ServiceType','ClusterIP','ExternalIP','Ports',
    'Roles','Unschedulable','SecretType','DataKeys'
)
