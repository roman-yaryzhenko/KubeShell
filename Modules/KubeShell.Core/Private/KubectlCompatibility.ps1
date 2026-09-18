# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Get-KubeExecutable {
    [CmdletBinding()]
    param()

    if ($script:KubectlPath -and (Test-Path -LiteralPath $script:KubectlPath)) {
        return $script:KubectlPath
    }

    # This resolver is intentionally for the compatibility/external CLI lane. Typed Runtime
    # operations use KubeShell.Kubectl over IPC; only Invoke-Kubectl and remaining legacy paths
    # should arrive here.
    $command = Get-Command kubectl -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $script:KubectlPath = [string]$command.Source
    return $script:KubectlPath
}
function Get-KubeBundledHostExecutable {
    [CmdletBinding()]
    param()

    if ($script:KubectlHostPath -and (Test-Path -LiteralPath $script:KubectlHostPath)) {
        return $script:KubectlHostPath
    }

    $configured = [Environment]::GetEnvironmentVariable('KUBESHELL_KUBECTL_HOST')
    if (-not [string]::IsNullOrWhiteSpace($configured) -and (Test-Path -LiteralPath $configured -PathType Leaf)) {
        $script:KubectlHostPath = $configured
        return $script:KubectlHostPath
    }

    $locatorType = 'KubeShell.Backends.Kubectl.KubectlHostLocator' -as [type]
    if ($null -ne $locatorType) {
        $bundled = [KubeShell.Backends.Kubectl.KubectlHostLocator]::TryResolveBundled()
        if (-not [string]::IsNullOrWhiteSpace([string]$bundled)) {
            $script:KubectlHostPath = [string]$bundled
            return $script:KubectlHostPath
        }
    }

    $command = Get-Command kubeshell-kubectl-host -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $script:KubectlHostPath = [string]$command.Source
        return $script:KubectlHostPath
    }

    throw 'The bundled kubeshell-kubectl-host executable was not found. Build/package KubeShell.Kubectl for this platform.'
}

function Get-KubeEffectiveArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $ArgumentList)

    $target = Get-KubeRuntimeTarget
    return [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::BuildEffectiveArguments($target, $ArgumentList, $true, $true)
}
function Set-KubeProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Diagnostics.ProcessStartInfo] $ProcessStartInfo)

    [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::ApplyEnvironment((Get-KubeRuntimeTarget), $ProcessStartInfo)
}
function New-KubeNativeErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string] $ErrorId,
        [Parameter(Mandatory)] [System.Management.Automation.ErrorCategory] $Category,
        [object] $TargetObject
    )

    $exception = [System.InvalidOperationException]::new($Message)
    return [System.Management.Automation.ErrorRecord]::new(
        $exception,
        $ErrorId,
        $Category,
        $TargetObject
    )
}
function Invoke-KubectlResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [AllowNull()] [string] $InputText
    )

    $transport = [KubeShell.Backends.KubectlProcess.KubectlProcessTransport]::new((Get-KubeExecutable))
    $target = Get-KubeRuntimeTarget
    $response = $transport.Execute($target, $ArgumentList, $InputText, $true, $true)

    [pscustomobject]@{
        PSTypeName = 'KubeShell.NativeResult'
        ExitCode   = $response.ExitCode
        StdOut     = $response.StdOut
        StdErr     = $response.StdErr
        Arguments  = @($response.Arguments)
    }
}
function Assert-KubectlSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Result,
        [object] $TargetObject
    )

    process {
        if ($Result.ExitCode -eq 0) {
            return $Result
        }

        $message = if ([string]::IsNullOrWhiteSpace($Result.StdErr)) {
            "kubectl exited with code $($Result.ExitCode)."
        }
        else {
            $Result.StdErr.Trim()
        }

        $errorRecord = New-KubeNativeErrorRecord -Message $message -ErrorId 'KubeShell.KubectlFailed' -Category InvalidOperation -TargetObject $TargetObject
        throw $errorRecord
    }
}
function Invoke-KubectlText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [AllowNull()] [string] $InputText
    )

    $result = Invoke-KubectlResult -ArgumentList $ArgumentList -InputText $InputText
    $result = Assert-KubectlSuccess -Result $result -TargetObject ($ArgumentList -join ' ')
    return $result.StdOut
}
function Invoke-KubectlNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [switch] $IgnoreExitCode
    )

    $effectiveArguments = Get-KubeEffectiveArguments $ArgumentList
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Get-KubeExecutable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    Set-KubeProcessEnvironment $psi
    foreach ($argument in $effectiveArguments) { [void]$psi.ArgumentList.Add([string]$argument) }

    # Streams remain attached to the current terminal. ProcessStartInfo is used instead of
    # the call operator so a per-session KUBECONFIG can be passed without mutating $env:KUBECONFIG.
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw 'Failed to start kubectl.' }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $errorRecord = New-KubeNativeErrorRecord -Message "kubectl exited with code $exitCode." -ErrorId 'KubeShell.KubectlInteractiveFailed' -Category InvalidOperation -TargetObject ($effectiveArguments -join ' ')
        throw $errorRecord
    }
}
function Get-KubeBundledWorkerArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('attach','exec','port-forward')] [string] $Worker,
        [Parameter(Mandatory)] [string[]] $ArgumentList
    )

    if ($ArgumentList.Count -eq 0 -or $ArgumentList[0] -ne $Worker) {
        throw "Worker '$Worker' requires an argument list beginning with '$Worker'."
    }
    $effective = @(Get-KubeEffectiveArguments $ArgumentList)
    $commandIndex = [Array]::IndexOf([string[]]$effective, $Worker)
    if ($commandIndex -lt 0) { throw "Could not locate worker command '$Worker' after target argument projection." }
    $result = [Collections.Generic.List[string]]::new()
    [void]$result.Add("--worker=$Worker")
    for ($i = 0; $i -lt $effective.Count; $i++) {
        if ($i -ne $commandIndex) { [void]$result.Add([string]$effective[$i]) }
    }
    return $result.ToArray()
}

function New-KubeBundledWorkerProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('attach','exec','port-forward')] [string] $Worker,
        [Parameter(Mandatory)] [string[]] $ArgumentList
    )

    $workerArguments = Get-KubeBundledWorkerArguments -Worker $Worker -ArgumentList $ArgumentList
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Get-KubeBundledHostExecutable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    Set-KubeProcessEnvironment $psi
    foreach ($argument in $workerArguments) { [void]$psi.ArgumentList.Add([string]$argument) }
    return $psi
}

function Invoke-KubeBundledWorkerNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('attach','exec')] [string] $Worker,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [switch] $IgnoreExitCode
    )

    $psi = New-KubeBundledWorkerProcessStartInfo -Worker $Worker -ArgumentList $ArgumentList
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "Failed to start kubeshell $Worker worker." }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $errorRecord = New-KubeNativeErrorRecord -Message "kubeshell $Worker worker exited with code $exitCode." -ErrorId 'KubeShell.WorkerFailed' -Category InvalidOperation -TargetObject ($ArgumentList -join ' ')
        throw $errorRecord
    }
}

function Invoke-KubeAttachWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $ArgumentList)
    Invoke-KubeBundledWorkerNative -Worker attach -ArgumentList $ArgumentList
}

function Invoke-KubeBundledWorkerResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('exec')] [string] $Worker,
        [Parameter(Mandatory)] [string[]] $ArgumentList
    )

    $psi = New-KubeBundledWorkerProcessStartInfo -Worker $Worker -ArgumentList $ArgumentList
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "Failed to start kubeshell $Worker worker." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{
            PSTypeName = 'KubeShell.NativeResult'
            ExitCode   = $process.ExitCode
            StdOut     = $stdoutTask.GetAwaiter().GetResult()
            StdErr     = $stderrTask.GetAwaiter().GetResult()
            Arguments  = @($psi.ArgumentList)
        }
    }
    finally {
        $process.Dispose()
    }
}
