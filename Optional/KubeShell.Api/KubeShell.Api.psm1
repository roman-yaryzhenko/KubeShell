Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../Modules/KubeShell.Core/KubeShell.Core.psd1') -Scope Local

function New-KubeApiSession {
    [CmdletBinding(DefaultParameterSetName='Explicit')]
    param(
        [Parameter(Mandatory,ParameterSetName='Explicit')]
        [uri] $Server,

        [Parameter(ParameterSetName='Explicit')]
        [string] $Token,

        [Parameter(ParameterSetName='Explicit')]
        [Security.Cryptography.X509Certificates.X509Certificate2] $ClientCertificate,

        [Parameter(ParameterSetName='Explicit')]
        [Security.Cryptography.X509Certificates.X509Certificate2] $CertificateAuthority,

        [Parameter(Mandatory,ParameterSetName='Kubectl')]
        [switch] $FromKubectlContext,

        [Parameter(ParameterSetName='Kubectl')]
        [string] $Context,

        [string] $DefaultNamespace='default',
        [switch] $SkipCertificateCheck
    )

    if ($PSCmdlet.ParameterSetName -eq 'Kubectl') {
        $state = Get-KubeSessionState
        $contextName = if ($Context) { $Context } else { [string]$state.Context }
        if (-not [string]::IsNullOrWhiteSpace([string]$state.Namespace)) {
            $DefaultNamespace = [string]$state.Namespace
        }
        $target = [KubeShell.Runtime.KubeTarget]::new(
            $contextName,
            [string[]]@($state.KubeConfigPaths),
            $DefaultNamespace,
            [string]$state.Profile,
            [string]$state.ConfigSet,
            'ApiSession'
        )
        # A kubectl-context API session consumes the same semantic Runtime ports as ordinary cmdlets.
        # Backend composition remains entirely inside Core.
        $client = New-KubeRuntimeResourceClient
        $discoveryClient = New-KubeRuntimeDiscoveryClient
        $plainToken = $null
        $sessionServer = $null
    }
    else {
        $contextName = $null
        $plainToken = if ([string]::IsNullOrWhiteSpace($Token)) { $null } else { [string]$Token }
        $target = [KubeShell.Runtime.KubeTarget]::new($null, [string[]]@(), $DefaultNamespace, $null, $null, 'ApiSession')
        $clients = New-KubeManagedExplicitRuntimeClients `
            -Server $Server `
            -Token $plainToken `
            -ClientCertificate $ClientCertificate `
            -CertificateAuthority $CertificateAuthority `
            -SkipCertificateCheck:$SkipCertificateCheck `
            -DefaultNamespace $DefaultNamespace
        $client = $clients.ResourceClient
        $discoveryClient = $clients.DiscoveryClient
        $sessionServer = $Server.AbsoluteUri.TrimEnd('/')
    }

    $runtimeExecutionContext = [KubeShell.Runtime.KubeExecutionContext]::Default
    [pscustomobject]@{
        PSTypeName           = 'KubeShell.ApiSession'
        Server               = $sessionServer
        Token                = if ($null -eq $plainToken) { $null } else { ConvertTo-SecureString $plainToken -AsPlainText -Force }
        ClientCertificate    = $ClientCertificate
        CertificateAuthority = $CertificateAuthority
        DefaultNamespace     = $DefaultNamespace
        SkipCertificateCheck = [bool]$SkipCertificateCheck
        Context              = $contextName
        Target               = $target
        ExecutionContext     = $runtimeExecutionContext
        Client               = $client
        DiscoveryClient      = $discoveryClient
        DiscoveryCache       = @{}
    }
}

function Invoke-KubeApiClientGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceQuery] $Query
    )
    try { return $Session.Client.Get($Session.Target, $Query, $Session.ExecutionContext) }
    catch [KubeShell.Runtime.KubeException] { throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Query) }
}

function Invoke-KubeApiClientPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [string] $PayloadJson,
        [Parameter(Mandatory)] [KubeShell.Runtime.KubePatchOptions] $Options
    )
    try { return $Session.Client.Patch($Session.Target, $Identity, $PayloadJson, $Options, $Session.ExecutionContext) }
    catch [KubeShell.Runtime.KubeException] { throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity) }
}

function Invoke-KubeApiClientDelete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [KubeShell.Runtime.ResourceIdentity] $Identity,
        [Parameter(Mandatory)] [KubeShell.Runtime.KubeDeleteOptions] $Options
    )
    try { $Session.Client.Delete($Session.Target, $Identity, $Options, $Session.ExecutionContext) }
    catch [KubeShell.Runtime.KubeException] { throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $Identity) }
}

function Get-KubeApiDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] $Session,
        [string] $ApiVersion='v1',
        [switch] $Refresh
    )

    if (-not $Refresh -and $Session.DiscoveryCache.ContainsKey($ApiVersion)) {
        return $Session.DiscoveryCache[$ApiVersion]
    }

    try {
        $descriptors = @($Session.DiscoveryClient.GetApiVersionResources($Session.Target, $ApiVersion, $Session.ExecutionContext, [bool]$Refresh))
        $result = [pscustomobject]@{
            PSTypeName   = 'KubeShell.ApiDiscovery'
            GroupVersion = $ApiVersion
            Resources    = @($descriptors | ForEach-Object {
                [pscustomobject]@{
                    Gvr          = $_.Gvr
                    Name         = $_.Gvr.Resource
                    Kind         = $_.Kind
                    SingularName = $_.SingularName
                    ShortNames   = @($_.ShortNames)
                    Categories   = @($_.Categories)
                    Namespaced   = $_.Namespaced
                    Verbs        = @($_.Verbs)
                    Subresources = @($_.Subresources)
                    SubresourceDetails = $_.SubresourceDetails
                }
            })
        }
        $Session.DiscoveryCache[$ApiVersion] = $result
        return $result
    }
    catch [KubeShell.Runtime.KubeException] { throw (New-KubeRuntimeErrorRecord -Exception $_.Exception -TargetObject $ApiVersion) }
}

function Resolve-KubeApiResourceMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Resource,
        [string] $ApiVersion='v1'
    )

    $discovery = Get-KubeApiDiscovery -Session $Session -ApiVersion $ApiVersion
    $match = @($discovery.Resources | Where-Object {
        $_.Name -ieq $Resource -or
        $_.SingularName -ieq $Resource -or
        @($_.ShortNames) -icontains $Resource
    } | Select-Object -First 1)
    if ($match.Count -eq 0) { throw "Kubernetes resource '$Resource' was not found in API version '$ApiVersion'." }
    return $match[0]
}

function Resolve-KubeApiNamespaceScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] $Session,
        [string] $Namespace,
        [switch] $AllNamespaces
    )

    if (-not [bool]$Metadata.Namespaced) { return [KubeShell.Runtime.KubeNamespaceScope]::Cluster }
    if ($AllNamespaces) { return [KubeShell.Runtime.KubeNamespaceScope]::All }
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) { return [KubeShell.Runtime.KubeNamespaceScope]::Explicit($Namespace) }
    if (-not [string]::IsNullOrWhiteSpace([string]$Session.DefaultNamespace)) { return [KubeShell.Runtime.KubeNamespaceScope]::Explicit([string]$Session.DefaultNamespace) }
    return [KubeShell.Runtime.KubeNamespaceScope]::Default
}

function Get-KubeApiResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] $Session,
        [Parameter(Mandatory,Position=1)] [string] $Resource,
        [Parameter(Position=2)] [string] $Name,
        [string] $ApiVersion='v1',
        [string] $Namespace,
        [switch] $AllNamespaces,
        [Alias('Label')] [string] $LabelSelector,
        [Alias('Field')] [string] $FieldSelector
    )

    $metadata = Resolve-KubeApiResourceMetadata -Session $Session -Resource $Resource -ApiVersion $ApiVersion
    $scope = Resolve-KubeApiNamespaceScope -Metadata $metadata -Session $Session -Namespace $Namespace -AllNamespaces:$AllNamespaces
    $query = [KubeShell.Runtime.ResourceQuery]::new(
        $metadata.Gvr, $Name, $scope, $LabelSelector, $FieldSelector, $null
    )
    foreach ($runtimeResource in @(Invoke-KubeApiClientGet -Session $Session -Query $query)) {
        ConvertFrom-KubeRuntimeResource $runtimeResource
    }
}

function Set-KubeApiResourcePatch {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory,Position=0)] $Session,
        [Parameter(Mandatory,Position=1)] [string] $Resource,
        [Parameter(Mandatory,Position=2)] [string] $Name,
        [Parameter(Mandatory)] $Patch,
        [string] $ApiVersion='v1',
        [string] $Namespace,
        [ValidateSet('Merge','Json','Strategic')] [string] $Type='Merge',
        [switch] $DryRunServer
    )

    if (-not $PSCmdlet.ShouldProcess("$ApiVersion/$Resource/$Name",'Patch Kubernetes resource through semantic API routing')) { return }
    $json = if ($Patch -is [string]) { [string]$Patch } else { $Patch | ConvertTo-Json -Depth 100 -Compress }
    $metadata = Resolve-KubeApiResourceMetadata -Session $Session -Resource $Resource -ApiVersion $ApiVersion
    $scope = Resolve-KubeApiNamespaceScope -Metadata $metadata -Session $Session -Namespace $Namespace
    $identity = [KubeShell.Runtime.ResourceIdentity]::new($metadata.Gvr, $Name, $scope, $null, $metadata.Kind)
    $patchType = [KubeShell.Runtime.KubePatchType]([Enum]::Parse([KubeShell.Runtime.KubePatchType], $Type, $true))
    $dryRun = if ($DryRunServer) { [KubeShell.Runtime.KubeDryRunMode]::Server } else { [KubeShell.Runtime.KubeDryRunMode]::None }
    $options = [KubeShell.Runtime.KubePatchOptions]::new($patchType, $dryRun)
    $runtimeResource = Invoke-KubeApiClientPatch -Session $Session -Identity $identity -PayloadJson $json -Options $options
    ConvertFrom-KubeRuntimeResource $runtimeResource
}

function Remove-KubeApiResource {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory,Position=0)] $Session,
        [Parameter(Mandatory,Position=1)] [string] $Resource,
        [Parameter(Mandatory,Position=2)] [string] $Name,
        [string] $ApiVersion='v1',
        [string] $Namespace,
        [switch] $DryRunServer
    )

    if (-not $PSCmdlet.ShouldProcess("$ApiVersion/$Resource/$Name",'Delete Kubernetes resource through semantic API routing')) { return }
    $metadata = Resolve-KubeApiResourceMetadata -Session $Session -Resource $Resource -ApiVersion $ApiVersion
    $scope = Resolve-KubeApiNamespaceScope -Metadata $metadata -Session $Session -Namespace $Namespace
    $identity = [KubeShell.Runtime.ResourceIdentity]::new($metadata.Gvr, $Name, $scope, $null, $metadata.Kind)
    $dryRunName = if ($DryRunServer) { 'Server' } else { 'None' }
    $options = [KubeShell.Runtime.KubeDeleteOptions]::new((ConvertTo-KubeRuntimeDryRunMode $dryRunName), $false, $null)
    Invoke-KubeApiClientDelete -Session $Session -Identity $identity -Options $options
    New-KubeChangeResult -Operation Delete -Identity $identity -DryRun $dryRunName
}

Export-ModuleMember -Function @(
    'New-KubeApiSession','Get-KubeApiDiscovery','Get-KubeApiResource',
    'Set-KubeApiResourcePatch','Remove-KubeApiResource'
)
