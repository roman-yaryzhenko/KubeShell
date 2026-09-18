# Internal implementation for KubeShell.Operations. Loaded into the parent module scope.

function Start-KubePortForward {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $InputObject,
        [Parameter(Mandatory)] [ValidateRange(1,65535)] [int] $LocalPort,
        [ValidateRange(1,65535)] [int] $RemotePort,
        [string] $Namespace,
        [string] $Resource,
        [string] $Address='127.0.0.1'
    )
    process {
        $identity = Resolve-KubeIdentity $InputObject $Namespace
        $resourceName = if ($Resource) { $Resource } elseif ($identity.Kind) { Resolve-KubeResourceName $identity.Kind } else { 'pod' }
        $target = "$resourceName/$($identity.Name)"
        $remote = if ($RemotePort) { $RemotePort } else { $LocalPort }

        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($arg in @('port-forward',$target,"$LocalPort`:$remote","--address=$Address")) { [void]$arguments.Add($arg) }
        if ($identity.Namespace) { [void]$arguments.Add('-n'); [void]$arguments.Add($identity.Namespace) }

        $psi = New-KubeBundledWorkerProcessStartInfo -Worker port-forward -ArgumentList $arguments.ToArray()
        $process = [Diagnostics.Process]::Start($psi)
        if ($null -eq $process) { throw 'Failed to start KubeShell port-forward worker.' }

        [pscustomobject]@{
            PSTypeName = 'KubeShell.PortForward'
            Id         = $process.Id
            Process    = $process
            Target     = $target
            Namespace  = $identity.Namespace
            LocalPort  = $LocalPort
            RemotePort = $remote
            Address    = $Address
        }
    }
}
function Stop-KubePortForward {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param([Parameter(Mandatory,ValueFromPipeline)] $PortForward)
    process {
        $process = if ($PortForward -is [Diagnostics.Process]) { $PortForward } else { $PortForward.Process }
        if ($process -and -not $process.HasExited -and $PSCmdlet.ShouldProcess("PID $($process.Id)", 'Stop KubeShell port-forward worker')) {
            $process.Kill($true)
            $process.WaitForExit()
        }
    }
}
