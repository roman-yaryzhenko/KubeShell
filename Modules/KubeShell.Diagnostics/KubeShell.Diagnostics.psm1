Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Core/KubeShell.Core.psd1') -Scope Local
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Resources/KubeShell.Resources.psd1') -Scope Local

function New-KubeDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Info','Warning','Error')] [string] $Severity,
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [string] $Message,
        [object] $Object
    )
    [pscustomobject]@{
        PSTypeName = 'KubeShell.Diagnostic'
        Severity   = $Severity
        Component  = $Component
        Check      = $Check
        Message    = $Message
        Object     = $Object
    }
}

function Get-KubeCondition {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $InputObject, [string] $Type)
    process {
        $identity = Resolve-KubeIdentity $InputObject
        foreach ($condition in @(Get-KubePropertyValue $InputObject @('status','conditions'))) {
            if ($null -eq $condition) { continue }
            $conditionType = [string](Get-KubePropertyValue $condition @('type'))
            if ($Type -and $conditionType -ne $Type) { continue }
            [pscustomobject]@{
                PSTypeName        = 'KubeShell.Condition'
                Resource          = "$($identity.Kind)/$($identity.Name)"
                Namespace         = $identity.Namespace
                Type              = $conditionType
                Status            = [string](Get-KubePropertyValue $condition @('status'))
                Reason            = [string](Get-KubePropertyValue $condition @('reason'))
                Message           = [string](Get-KubePropertyValue $condition @('message'))
                LastTransitionTime= Get-KubePropertyValue $condition @('lastTransitionTime')
                Raw               = $condition
            }
        }
    }
}

function Get-KubeOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $InputObject, [switch] $Resolve)
    process {
        $identity = Resolve-KubeIdentity $InputObject
        foreach ($owner in @(Get-KubePropertyValue $InputObject @('metadata','ownerReferences'))) {
            if ($null -eq $owner) { continue }
            $ownerInfo = [pscustomobject]@{
                PSTypeName = 'KubeShell.OwnerReference'
                Name       = [string](Get-KubePropertyValue $owner @('name'))
                Kind       = [string](Get-KubePropertyValue $owner @('kind'))
                ApiVersion = [string](Get-KubePropertyValue $owner @('apiVersion'))
                Uid        = [string](Get-KubePropertyValue $owner @('uid'))
                Controller = [bool]((Get-KubePropertyValue $owner @('controller')) ?? $false)
                Namespace  = $identity.Namespace
            }
            if (-not $Resolve) { $ownerInfo; continue }
            $resource = Resolve-KubeResourceName $ownerInfo.Kind
            $params = @{ Resource=$resource; Name=$ownerInfo.Name }
            if ($identity.Namespace) { $params.Namespace=$identity.Namespace }
            Get-KubeResource @params
        }
    }
}

function Get-KubeDependent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)] $InputObject,
        [string[]] $Resource = @('pod','replicaset','deployment','statefulset','daemonset','job','cronjob')
    )
    process {
        $uid = [string](Get-KubePropertyValue $InputObject @('metadata','uid'))
        $identity = Resolve-KubeIdentity $InputObject
        if (-not $uid) { throw 'Input object has no metadata.uid.' }
        foreach ($resourceType in $Resource) {
            $params = @{ Resource=$resourceType }
            if ($identity.Namespace) { $params.Namespace=$identity.Namespace }
            foreach ($candidate in @(Get-KubeResource @params)) {
                $owners = @(Get-KubePropertyValue $candidate @('metadata','ownerReferences'))
                if ($owners | Where-Object { (Get-KubePropertyValue $_ @('uid')) -eq $uid }) { $candidate }
            }
        }
    }
}

function Get-KubeEventsFor {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $InputObject)
    process {
        $identity = Resolve-KubeIdentity $InputObject
        $uid = Get-KubePropertyValue $InputObject @('metadata','uid')
        $selector = if ($uid) { "involvedObject.uid=$uid" } else { "involvedObject.name=$($identity.Name)" }
        $params = @{ FieldSelector=$selector }
        if ($identity.Namespace) { $params.Namespace=$identity.Namespace }
        Get-KubeEvent @params
    }
}

function Test-KubePod {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $Pod, [string] $Namespace)
    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $object = if ($Pod -is [string]) { Get-KubePod $identity.Name -Namespace $identity.Namespace } else { $Pod }
        $component = "$($identity.Namespace)/pod/$($identity.Name)"
        $phase = (Get-KubePropertyValue $object @('status','phase')) ?? 'Unknown'
        $ready = [bool](Get-KubePropertyValue $object @('Healthy'))
        New-KubeDiagnostic $(if ($phase -eq 'Running') {'Info'} else {'Warning'}) $component 'Phase' "Pod phase: $phase" $object
        New-KubeDiagnostic $(if ($ready) {'Info'} else {'Warning'}) $component 'Ready' "Containers ready: $((Get-KubePropertyValue $object @('Ready')) ?? 'unknown')" $object

        foreach ($status in @(Get-KubePropertyValue $object @('status','containerStatuses'))) {
            if ($null -eq $status) { continue }
            $name = Get-KubePropertyValue $status @('name')
            $restarts = [int]((Get-KubePropertyValue $status @('restartCount')) ?? 0)
            if ($restarts -gt 0) { New-KubeDiagnostic 'Warning' $component "Restart:$name" "Container $name has restarted $restarts time(s)." $status }
            $reason = Get-KubePropertyValue $status @('lastState','terminated','reason')
            if ($reason) { New-KubeDiagnostic 'Warning' $component "LastTermination:$name" "Last termination reason: $reason" $status }
        }

        foreach ($event in @(Get-KubeEventsFor $object | Where-Object { (Get-KubePropertyValue $_ @('type')) -eq 'Warning' })) {
            $reason = (Get-KubePropertyValue $event @('reason')) ?? 'Event'
            $message = (Get-KubePropertyValue $event @('message')) ?? ''
            New-KubeDiagnostic 'Warning' $component "Event:$reason" $message $event
        }
    }
}

function Test-KubeDeployment {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $Deployment, [string] $Namespace)
    process {
        $identity = Resolve-KubeIdentity $Deployment $Namespace 'Deployment'
        $object = if ($Deployment -is [string]) { Get-KubeDeployment $identity.Name -Namespace $identity.Namespace } else { $Deployment }
        $component = "$($identity.Namespace)/deployment/$($identity.Name)"
        $desired = [int]((Get-KubePropertyValue $object @('Desired')) ?? 0)
        $available = [int]((Get-KubePropertyValue $object @('Available')) ?? 0)
        $updated = [int]((Get-KubePropertyValue $object @('Updated')) ?? 0)
        $healthy = [bool](Get-KubePropertyValue $object @('Healthy'))
        New-KubeDiagnostic $(if ($healthy) {'Info'} else {'Warning'}) $component 'Replicas' "Desired=$desired Updated=$updated Available=$available" $object
        foreach ($condition in @(Get-KubeCondition $object)) {
            if ($condition.Status -eq 'False' -or $condition.Reason -match 'Failed|Error') {
                New-KubeDiagnostic 'Warning' $component "Condition:$($condition.Type)" "$($condition.Reason): $($condition.Message)" $condition
            }
        }
        foreach ($event in @(Get-KubeEventsFor $object | Where-Object { (Get-KubePropertyValue $_ @('type')) -eq 'Warning' })) {
            New-KubeDiagnostic 'Warning' $component "Event:$((Get-KubePropertyValue $event @('reason')) ?? 'Event')" ((Get-KubePropertyValue $event @('message')) ?? '') $event
        }
    }
}

function Test-KubeCluster {
    [CmdletBinding()]
    param()

    foreach ($node in @(Get-KubeNode)) {
        New-KubeDiagnostic $(if ($node.Ready) {'Info'} else {'Error'}) "node/$($node.Name)" 'Ready' "Ready=$($node.Ready), Unschedulable=$($node.Unschedulable)" $node
    }

    $systemPods = @(Get-KubePod -Namespace kube-system)
    $dnsPods = @($systemPods | Where-Object { $_.Name -like '*coredns*' -or $_.Name -like '*kube-dns*' })
    if ($dnsPods.Count -eq 0) {
        New-KubeDiagnostic 'Warning' 'cluster/dns' 'Discovery' 'No CoreDNS/kube-dns pod was found in kube-system.' $null
    }
    else {
        foreach ($pod in $dnsPods) {
            New-KubeDiagnostic $(if ($pod.Healthy) {'Info'} else {'Error'}) "kube-system/pod/$($pod.Name)" 'DNS' "Phase=$($pod.Phase) Ready=$($pod.Ready)" $pod
        }
    }

    foreach ($pod in @(Get-KubePod -AllNamespaces | Where-Object { $_.Phase -notin @('Running','Succeeded') })) {
        New-KubeDiagnostic 'Warning' "$($pod.Namespace)/pod/$($pod.Name)" 'WorkloadPhase' "Phase=$($pod.Phase) Ready=$($pod.Ready)" $pod
    }
}

function Test-KubeAccess {
    [CmdletBinding(DefaultParameterSetName='Resource')]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Verb,
        [Parameter(Mandatory,Position=1,ParameterSetName='Resource')] [string] $Resource,
        [Parameter(ParameterSetName='Resource')] [string] $Name,
        [string] $Namespace,
        [string] $As,
        [string[]] $AsGroup
    )

    $parts = $Resource -split '/', 2
    $descriptor = Invoke-KubeRuntimeResolveResource -Resource $parts[0]
    $subresource = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    $review = Invoke-KubeRuntimeAccessReview `
        -Verb $Verb `
        -Resource $descriptor.Gvr.Resource `
        -Name $Name `
        -Namespace $Namespace `
        -Group $descriptor.Gvr.Group `
        -Subresource $subresource `
        -Namespaced ([bool]$descriptor.Namespaced) `
        -As $As `
        -AsGroup $AsGroup
    [pscustomobject]@{
        PSTypeName      = 'KubeShell.AccessCheck'
        Allowed         = $review.Allowed
        Denied          = $review.Denied
        Verb            = $Verb
        Resource        = $Resource
        Name            = $Name
        Namespace       = $Namespace
        As              = $As
        Reason          = $review.Reason
        EvaluationError = $review.EvaluationError
    }
}

function Get-KubeTopPod {
    [CmdletBinding()]
    param([string] $Namespace, [switch] $AllNamespaces)

    $metricsNamespace = if ($AllNamespaces -or -not $Namespace) { $null } else { $Namespace }
    $metrics = (Invoke-KubeRuntimePodMetrics -Namespace $metricsNamespace) | ConvertFrom-Json -Depth 100
    foreach ($pod in @(Get-KubePropertyValue $metrics @('items'))) {
        if ($null -eq $pod) { continue }
        $cpu = 0.0; $memory = [int64]0
        foreach ($container in @(Get-KubePropertyValue $pod @('containers'))) {
            if ($null -eq $container) { continue }
            $cpu += ConvertFrom-KubeCpuQuantity ([string](Get-KubePropertyValue $container @('usage','cpu')))
            $memory += ConvertFrom-KubeMemoryQuantity ([string](Get-KubePropertyValue $container @('usage','memory')))
        }
        $timestampText = Get-KubePropertyValue $pod @('timestamp')
        $timestamp = if ($timestampText) { [datetimeoffset]$timestampText } else { $null }
        [pscustomobject]@{
            PSTypeName    = 'KubeShell.PodMetrics'
            Name          = [string](Get-KubePropertyValue $pod @('metadata','name'))
            Namespace     = [string](Get-KubePropertyValue $pod @('metadata','namespace'))
            CpuCores      = $cpu
            CpuMillicores = [math]::Round($cpu * 1000, 3)
            MemoryBytes   = $memory
            MemoryMiB     = [math]::Round($memory / 1MB, 2)
            Timestamp     = $timestamp
        }
    }
}

function Get-KubeTopNode {
    [CmdletBinding()]
    param()
    $metrics = (Invoke-KubeRuntimeNodeMetrics) | ConvertFrom-Json -Depth 100
    foreach ($node in @(Get-KubePropertyValue $metrics @('items'))) {
        if ($null -eq $node) { continue }
        $cpu = ConvertFrom-KubeCpuQuantity ([string](Get-KubePropertyValue $node @('usage','cpu')))
        $memory = ConvertFrom-KubeMemoryQuantity ([string](Get-KubePropertyValue $node @('usage','memory')))
        $timestampText = Get-KubePropertyValue $node @('timestamp')
        $timestamp = if ($timestampText) { [datetimeoffset]$timestampText } else { $null }
        [pscustomobject]@{
            PSTypeName    = 'KubeShell.NodeMetrics'
            Name          = [string](Get-KubePropertyValue $node @('metadata','name'))
            CpuCores      = $cpu
            CpuMillicores = [math]::Round($cpu * 1000, 3)
            MemoryBytes   = $memory
            MemoryMiB     = [math]::Round($memory / 1MB, 2)
            Timestamp     = $timestamp
        }
    }
}

function Get-KubeContainerResources {
    [CmdletBinding()]
    param([AllowNull()] $Container)
    if ($null -eq $Container) { return [pscustomobject]@{ RequestCpu=0.0; RequestMemory=0L; LimitCpu=0.0; LimitMemory=0L } }
    [pscustomobject]@{
        RequestCpu    = ConvertFrom-KubeCpuQuantity ([string](Get-KubePropertyValue $Container @('resources','requests','cpu')))
        RequestMemory = ConvertFrom-KubeMemoryQuantity ([string](Get-KubePropertyValue $Container @('resources','requests','memory')))
        LimitCpu      = ConvertFrom-KubeCpuQuantity ([string](Get-KubePropertyValue $Container @('resources','limits','cpu')))
        LimitMemory   = ConvertFrom-KubeMemoryQuantity ([string](Get-KubePropertyValue $Container @('resources','limits','memory')))
    }
}

function Get-KubePodEffectiveResources {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pod)

    # Pod-level resources are available in current Kubernetes releases. When present,
    # they are the aggregate budget and are therefore the correct node-accounting value.
    $podRequestCpu = Get-KubePropertyValue $Pod @('spec','resources','requests','cpu')
    $podRequestMemory = Get-KubePropertyValue $Pod @('spec','resources','requests','memory')
    $podLimitCpu = Get-KubePropertyValue $Pod @('spec','resources','limits','cpu')
    $podLimitMemory = Get-KubePropertyValue $Pod @('spec','resources','limits','memory')
    $hasPodLevelResources = $null -ne $podRequestCpu -or $null -ne $podRequestMemory -or $null -ne $podLimitCpu -or $null -ne $podLimitMemory

    if ($hasPodLevelResources) {
        return [pscustomobject]@{
            RequestCpu    = ConvertFrom-KubeCpuQuantity ([string]$podRequestCpu)
            RequestMemory = ConvertFrom-KubeMemoryQuantity ([string]$podRequestMemory)
            LimitCpu      = ConvertFrom-KubeCpuQuantity ([string]$podLimitCpu)
            LimitMemory   = ConvertFrom-KubeMemoryQuantity ([string]$podLimitMemory)
        }
    }

    $running = [pscustomobject]@{ RequestCpu=0.0; RequestMemory=0L; LimitCpu=0.0; LimitMemory=0L }
    foreach ($container in @(Get-KubePropertyValue $Pod @('spec','containers'))) {
        if ($null -eq $container) { continue }
        $r = Get-KubeContainerResources $container
        $running.RequestCpu += $r.RequestCpu; $running.RequestMemory += $r.RequestMemory
        $running.LimitCpu += $r.LimitCpu; $running.LimitMemory += $r.LimitMemory
    }

    # Native sidecars live in initContainers with restartPolicy=Always. They remain active
    # with app containers, and earlier sidecars also overlap later regular init containers.
    $sidecars = [pscustomobject]@{ RequestCpu=0.0; RequestMemory=0L; LimitCpu=0.0; LimitMemory=0L }
    $initPeak = [pscustomobject]@{ RequestCpu=0.0; RequestMemory=0L; LimitCpu=0.0; LimitMemory=0L }
    foreach ($container in @(Get-KubePropertyValue $Pod @('spec','initContainers'))) {
        if ($null -eq $container) { continue }
        $r = Get-KubeContainerResources $container
        $isSidecar = (Get-KubePropertyValue $container @('restartPolicy')) -eq 'Always'
        if ($isSidecar) {
            $sidecars.RequestCpu += $r.RequestCpu; $sidecars.RequestMemory += $r.RequestMemory
            $sidecars.LimitCpu += $r.LimitCpu; $sidecars.LimitMemory += $r.LimitMemory
            $candidateRequestCpu = $sidecars.RequestCpu
            $candidateRequestMemory = $sidecars.RequestMemory
            $candidateLimitCpu = $sidecars.LimitCpu
            $candidateLimitMemory = $sidecars.LimitMemory
        }
        else {
            $candidateRequestCpu = $sidecars.RequestCpu + $r.RequestCpu
            $candidateRequestMemory = $sidecars.RequestMemory + $r.RequestMemory
            $candidateLimitCpu = $sidecars.LimitCpu + $r.LimitCpu
            $candidateLimitMemory = $sidecars.LimitMemory + $r.LimitMemory
        }
        $initPeak.RequestCpu = [math]::Max($initPeak.RequestCpu, $candidateRequestCpu)
        $initPeak.RequestMemory = [math]::Max($initPeak.RequestMemory, $candidateRequestMemory)
        $initPeak.LimitCpu = [math]::Max($initPeak.LimitCpu, $candidateLimitCpu)
        $initPeak.LimitMemory = [math]::Max($initPeak.LimitMemory, $candidateLimitMemory)
    }

    $running.RequestCpu += $sidecars.RequestCpu; $running.RequestMemory += $sidecars.RequestMemory
    $running.LimitCpu += $sidecars.LimitCpu; $running.LimitMemory += $sidecars.LimitMemory

    $overheadCpu = ConvertFrom-KubeCpuQuantity ([string](Get-KubePropertyValue $Pod @('spec','overhead','cpu')))
    $overheadMemory = ConvertFrom-KubeMemoryQuantity ([string](Get-KubePropertyValue $Pod @('spec','overhead','memory')))
    [pscustomobject]@{
        RequestCpu    = [math]::Max($running.RequestCpu,$initPeak.RequestCpu) + $overheadCpu
        RequestMemory = [math]::Max($running.RequestMemory,$initPeak.RequestMemory) + $overheadMemory
        LimitCpu      = [math]::Max($running.LimitCpu,$initPeak.LimitCpu) + $overheadCpu
        LimitMemory   = [math]::Max($running.LimitMemory,$initPeak.LimitMemory) + $overheadMemory
    }
}

function Get-KubeNodeAllocation {
    [CmdletBinding()]
    param()
    $nodes = @(Get-KubeNode)
    $pods = @(Get-KubePod -AllNamespaces | Where-Object { $_.Phase -notin @('Succeeded','Failed') })

    foreach ($node in $nodes) {
        $nodePods = @($pods | Where-Object Node -EQ $node.Name)
        $requestCpu=0.0; $requestMemory=[int64]0; $limitCpu=0.0; $limitMemory=[int64]0
        foreach ($pod in $nodePods) {
            $r = Get-KubePodEffectiveResources $pod
            $requestCpu += $r.RequestCpu; $requestMemory += $r.RequestMemory
            $limitCpu += $r.LimitCpu; $limitMemory += $r.LimitMemory
        }
        $allocCpu = ConvertFrom-KubeCpuQuantity ([string](Get-KubePropertyValue $node @('status','allocatable','cpu')))
        $allocMem = ConvertFrom-KubeMemoryQuantity ([string](Get-KubePropertyValue $node @('status','allocatable','memory')))
        [pscustomobject]@{
            PSTypeName        = 'KubeShell.NodeAllocation'
            Name              = $node.Name
            Pods              = $nodePods.Count
            AllocatableCpu    = $allocCpu
            RequestCpu        = $requestCpu
            LimitCpu          = $limitCpu
            RequestCpuPercent = if ($allocCpu) { [math]::Round(100*$requestCpu/$allocCpu,1) } else { $null }
            LimitCpuPercent   = if ($allocCpu) { [math]::Round(100*$limitCpu/$allocCpu,1) } else { $null }
            AllocatableMemoryBytes = $allocMem
            RequestMemoryBytes = $requestMemory
            LimitMemoryBytes   = $limitMemory
            RequestMemoryPercent = if ($allocMem) { [math]::Round(100*$requestMemory/$allocMem,1) } else { $null }
            LimitMemoryPercent   = if ($allocMem) { [math]::Round(100*$limitMemory/$allocMem,1) } else { $null }
        }
    }
}

function Get-KubeOvercommit {
    [CmdletBinding()]
    param()
    Get-KubeNodeAllocation | Select-Object Name,Pods,RequestCpuPercent,LimitCpuPercent,RequestMemoryPercent,LimitMemoryPercent
}

function Resolve-KubeService {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0,ValueFromPipeline)] $Service, [string] $Namespace)
    process {
        $identity = Resolve-KubeIdentity $Service $Namespace 'Service'
        $object = if ($Service -is [string]) { Get-KubeService $identity.Name -Namespace $identity.Namespace } else { $Service }
        $slices = @(Get-KubeEndpointSlice -Namespace $identity.Namespace -LabelSelector "kubernetes.io/service-name=$($identity.Name)")
        $selectorObject = Get-KubePropertyValue $object @('spec','selector')
        $selector = if ($selectorObject) { @($selectorObject.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',' } else { $null }
        $pods = if ($selector) { @(Get-KubePod -Namespace $identity.Namespace -LabelSelector $selector) } else { @() }
        [pscustomobject]@{
            PSTypeName     = 'KubeShell.ServiceResolution'
            Service        = $object
            EndpointSlices = $slices
            Pods           = $pods
            Selector       = $selector
        }
    }
}

function Test-KubeService {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)] $Service, [string] $Namespace)
    process {
        $resolution = Resolve-KubeService $Service $Namespace
        $svc = $resolution.Service
        $component = "$($svc.Namespace)/service/$($svc.Name)"
        $readyEndpoints = 0
        foreach ($slice in $resolution.EndpointSlices) {
            foreach ($endpoint in @(Get-KubePropertyValue $slice @('endpoints'))) {
                if ($null -eq $endpoint) { continue }
                $ready = Get-KubePropertyValue $endpoint @('conditions','ready')
                if ($null -eq $ready -or $ready) { $readyEndpoints++ }
            }
        }
        New-KubeDiagnostic $(if ($readyEndpoints -gt 0) {'Info'} else {'Warning'}) $component 'Endpoints' "Ready endpoints: $readyEndpoints; selected pods: $($resolution.Pods.Count)." $resolution
    }
}

function Test-KubeDns {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param(
        [string] $Namespace='default',
        [string] $Name='kubernetes.default.svc.cluster.local',
        [string] $Image='busybox:1.36',
        [ValidateRange(1,3600)] [int] $TimeoutSeconds = 60
    )
    $target = "$Namespace/dns-probe/$Name"
    if (-not $PSCmdlet.ShouldProcess($target, "Run ephemeral DNS probe for $Name")) { return }
    $result = Invoke-KubeRuntimeDnsProbe -Namespace $Namespace -Name $Name -Image $Image -Timeout ([timespan]::FromSeconds($TimeoutSeconds))
    [pscustomobject]@{
        PSTypeName = 'KubeShell.NetworkTest'
        Success    = $result.Success
        Target     = $Name
        Output     = $result.Output
    }
}

Export-ModuleMember -Function @(
    'Get-KubeCondition','Get-KubeOwner','Get-KubeDependent','Get-KubeEventsFor','Test-KubePod','Test-KubeDeployment','Test-KubeCluster',
    'Test-KubeAccess','Get-KubeTopPod','Get-KubeTopNode','Get-KubeNodeAllocation','Get-KubeOvercommit','Resolve-KubeService','Test-KubeService','Test-KubeDns'
)
