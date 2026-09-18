# Internal implementation for KubeShell.Operations. Loaded into the parent module scope.

function Invoke-KubeDebugContinuation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)

    foreach ($warning in @($Result.EffectiveWarnings)) {
        if ($warning -and $warning.Message) { Write-Warning $warning.Message }
    }
    if ($Result.Output) { Write-Verbose $Result.Output }

    $attachment = $Result.Attachment
    if ($null -eq $attachment -or $attachment.Continuation -eq [KubeShell.Runtime.KubeDebugContinuation]::None) { return }

    if ($attachment.Continuation -eq [KubeShell.Runtime.KubeDebugContinuation]::Logs) {
        Invoke-KubeRuntimeLog -Pod $attachment.Pod -Namespace $attachment.Namespace -Container $attachment.Container -Tail -1
        return
    }

    $args = [Collections.Generic.List[string]]::new()
    [void]$args.Add('attach')
    [void]$args.Add("pod/$($attachment.Pod)")
    if ($attachment.Namespace) { [void]$args.Add('-n'); [void]$args.Add($attachment.Namespace) }
    if ($attachment.Container) { [void]$args.Add('-c'); [void]$args.Add($attachment.Container) }
    if ($attachment.Interactive) { [void]$args.Add('-i') }
    if ($attachment.Tty) { [void]$args.Add('-t') }
    if ($attachment.Quiet) { [void]$args.Add('-q') }

    try {
        Invoke-KubeAttachWorker $args.ToArray()
    }
    catch {
        # kubectl debug falls back to logs when attach fails after the container has started.
        Write-Warning "Attach failed; falling back to debug-container logs: $($_.Exception.Message)"
        Invoke-KubeRuntimeLog -Pod $attachment.Pod -Namespace $attachment.Namespace -Container $attachment.Container -Tail -1
    }
}

function Enter-KubeDebugPod {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Pod,
        [string] $Namespace,
        [string] $TargetContainer,
        [string] $Image='ubuntu:24.04',
        [string] $Profile='general',
        [string[]] $Command=@('/bin/bash')
    )
    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        if (-not $PSCmdlet.ShouldProcess("$($identity.Namespace)/pod/$($identity.Name)", 'Add Kubernetes debug container')) { return }
        $scope = if ($identity.Namespace) {
            [KubeShell.Runtime.KubeNamespaceScope]::Explicit([string]$identity.Namespace)
        }
        else {
            [KubeShell.Runtime.KubeNamespaceScope]::Default
        }
        $target = [KubeShell.Runtime.ResourceIdentity]::new(
            [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'pods'),
            [string]$identity.Name,
            $scope,
            $null,
            'Pod'
        )
        $result = Invoke-KubeRuntimeDebug -Target $target -Image $Image -Command $Command -TargetContainer $TargetContainer -Profile $Profile
        Invoke-KubeDebugContinuation $result
    }
}

function Enter-KubeNode {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipelineByPropertyName)] [Alias('Name')] [string] $Node,
        [string] $Image='ubuntu:24.04',
        [string] $Profile='sysadmin',
        [switch] $Chroot
    )
    process {
        if (-not $PSCmdlet.ShouldProcess("node/$Node", 'Create Kubernetes node debug pod')) { return }
        $target = [KubeShell.Runtime.ResourceIdentity]::new(
            [KubeShell.Runtime.GroupVersionResource]::new('', 'v1', 'nodes'),
            $Node,
            [KubeShell.Runtime.KubeNamespaceScope]::Cluster,
            $null,
            'Node'
        )
        $command = if ($Chroot) { @('chroot','/host','/bin/bash') } else { @('/bin/bash') }
        $result = Invoke-KubeRuntimeDebug -Target $target -Image $Image -Command $command -Profile $Profile
        Invoke-KubeDebugContinuation $result
    }
}
