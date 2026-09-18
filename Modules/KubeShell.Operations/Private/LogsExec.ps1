# Internal implementation for KubeShell.Operations. Loaded into the parent module scope.

function Get-KubeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Pod,
        [string] $Namespace,
        [string] $Container,
        [ValidateRange(1,1000000)] [int] $Tail = 200,
        [timespan] $Since,
        [switch] $Previous,
        [switch] $Follow,
        [switch] $Timestamps,
        [switch] $Prefix
    )

    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $parameters = @{
            Pod        = $identity.Name
            Namespace  = $identity.Namespace
            Container  = $Container
            Tail       = $Tail
            Previous   = $Previous
            Follow     = $Follow
            Timestamps = $Timestamps
            Prefix     = $Prefix
        }
        if ($PSBoundParameters.ContainsKey('Since')) { $parameters.Since = $Since }
        Invoke-KubeRuntimeLog @parameters
    }
}

function Invoke-KubeExec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Pod,
        [string] $Namespace,
        [string] $Container,
        [Parameter(Position=1, ValueFromRemainingArguments)] [string[]] $Command = @('/bin/sh'),
        [switch] $NoTty
    )

    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $arguments = [Collections.Generic.List[string]]::new()
        [void]$arguments.Add('exec')
        [void]$arguments.Add($(if ($NoTty) { '-i' } else { '-it' }))
        if ($identity.Namespace) { [void]$arguments.Add('-n'); [void]$arguments.Add($identity.Namespace) }
        if ($Container) { [void]$arguments.Add('-c'); [void]$arguments.Add($Container) }
        [void]$arguments.Add($identity.Name); [void]$arguments.Add('--')
        foreach ($part in $Command) { [void]$arguments.Add($part) }
        Invoke-KubeBundledWorkerNative -Worker exec -ArgumentList $arguments.ToArray()
    }
}

function Enter-KubePod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)] $Pod,
        [string] $Namespace,
        [string] $Container,
        [ValidateSet('Auto','Bash','Sh')] [string] $Shell = 'Auto'
    )

    process {
        $identity = Resolve-KubeIdentity $Pod $Namespace 'Pod'
        $shellPath = switch ($Shell) {
            'Bash' { '/bin/bash' }
            'Sh' { '/bin/sh' }
            default {
                $probe = [Collections.Generic.List[string]]::new()
                [void]$probe.Add('exec'); [void]$probe.Add('-i')
                if ($identity.Namespace) { [void]$probe.Add('-n'); [void]$probe.Add($identity.Namespace) }
                if ($Container) { [void]$probe.Add('-c'); [void]$probe.Add($Container) }
                [void]$probe.Add($identity.Name); [void]$probe.Add('--'); [void]$probe.Add('/bin/bash'); [void]$probe.Add('-lc'); [void]$probe.Add('exit 0')
                $result = Invoke-KubeBundledWorkerResult -Worker exec -ArgumentList $probe.ToArray()
                if ($result.ExitCode -eq 0) { '/bin/bash' } else { '/bin/sh' }
            }
        }
        Invoke-KubeExec -Pod $Pod -Namespace $Namespace -Container $Container -Command $shellPath
    }
}
