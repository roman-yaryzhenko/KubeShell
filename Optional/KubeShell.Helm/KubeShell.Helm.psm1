Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../Modules/KubeShell.Core/KubeShell.Core.psd1') -Scope Local

function Get-HelmExecutable {
    [CmdletBinding()]
    param()

    $command = Get-Command helm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        throw 'helm executable was not found in PATH.'
    }
    return $command.Source
}


function Get-KubeEffectiveHelmArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $ArgumentList)

    $state = Get-KubeExecutionContext
    $effective = [Collections.Generic.List[string]]::new()
    $hasContext = $false
    $hasNamespace = $false
    $allNamespaces = $false
    foreach ($argument in $ArgumentList) {
        if ($argument -eq '--kube-context' -or $argument.StartsWith('--kube-context=')) { $hasContext = $true }
        if ($argument -eq '--namespace' -or $argument -eq '-n' -or $argument.StartsWith('--namespace=')) { $hasNamespace = $true }
        if ($argument -eq '--all-namespaces' -or $argument -eq '-A') { $allNamespaces = $true }
    }

    if (-not $hasContext -and -not [string]::IsNullOrEmpty([string]$state.Context)) {
        [void]$effective.Add('--kube-context')
        [void]$effective.Add([string]$state.Context)
    }
    if (-not $hasNamespace -and -not $allNamespaces -and -not [string]::IsNullOrWhiteSpace([string]$state.Namespace)) {
        [void]$effective.Add('--namespace')
        [void]$effective.Add([string]$state.Namespace)
    }
    foreach ($argument in $ArgumentList) { [void]$effective.Add($argument) }
    return $effective.ToArray()
}

function Invoke-HelmResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [AllowNull()] [string] $InputText
    )

    $effectiveArguments = Get-KubeEffectiveHelmArguments $ArgumentList
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Get-HelmExecutable
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($null -ne $InputText) { $psi.RedirectStandardInput = $true }
    Set-KubeProcessEnvironment $psi
    foreach ($argument in $effectiveArguments) { [void]$psi.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw 'Failed to start helm.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if ($null -ne $InputText) {
            $process.StandardInput.Write($InputText)
            $process.StandardInput.Close()
        }

        $process.WaitForExit()
        [pscustomobject]@{
            PSTypeName = 'KubeShell.HelmResult'
            ExitCode   = $process.ExitCode
            StdOut     = $stdoutTask.GetAwaiter().GetResult()
            StdErr     = $stderrTask.GetAwaiter().GetResult()
            Arguments  = $effectiveArguments
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-HelmJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $result = Invoke-HelmResult -ArgumentList $ArgumentList
    if ($result.ExitCode -ne 0) {
        throw ($result.StdErr.Trim() ?? "helm exited with code $($result.ExitCode).")
    }
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) { return $null }
    return $result.StdOut | ConvertFrom-Json -Depth 100
}

function ConvertTo-KubeHelmRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$InputObject)
    process {
        [pscustomobject]@{
            PSTypeName = 'KubeShell.HelmRelease'
            Name       = [string]$InputObject.name
            Namespace  = [string]$InputObject.namespace
            Revision   = [int]$InputObject.revision
            Updated    = [string]$InputObject.updated
            Status     = [string]$InputObject.status
            Chart      = [string]$InputObject.chart
            AppVersion = [string]$InputObject.app_version
            Raw        = $InputObject
        }
    }
}

function Get-KubeHelmRelease {
    [CmdletBinding(DefaultParameterSetName='Namespace')]
    param(
        [Parameter(Position=0)] [string] $Name,
        [Parameter(ParameterSetName='Namespace')] [string] $Namespace,
        [Parameter(ParameterSetName='AllNamespaces')] [switch] $AllNamespaces,
        [switch] $All
    )

    $arguments = [Collections.Generic.List[string]]::new()
    [void]$arguments.Add('list')
    [void]$arguments.Add('-o')
    [void]$arguments.Add('json')
    if ($AllNamespaces) { [void]$arguments.Add('--all-namespaces') }
    elseif ($Namespace) { [void]$arguments.Add('--namespace'); [void]$arguments.Add($Namespace) }
    if ($All) { [void]$arguments.Add('--all') }

    $items = @(Invoke-HelmJson -ArgumentList $arguments.ToArray())
    foreach ($item in $items) {
        $release = ConvertTo-KubeHelmRelease $item
        if (-not $Name -or $release.Name -eq $Name) { $release }
    }
}

function Get-KubeHelmValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [Alias('Name')] [string] $Release,
        [string] $Namespace,
        [switch] $All
    )
    process {
        $arguments = [Collections.Generic.List[string]]::new()
        [void]$arguments.Add('get')
        [void]$arguments.Add('values')
        [void]$arguments.Add($Release)
        [void]$arguments.Add('-o')
        [void]$arguments.Add('json')
        if ($Namespace) { [void]$arguments.Add('--namespace'); [void]$arguments.Add($Namespace) }
        if ($All) { [void]$arguments.Add('--all') }
        Invoke-HelmJson -ArgumentList $arguments.ToArray()
    }
}

function Get-KubeHelmHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [Alias('Name')] [string] $Release,
        [string] $Namespace,
        [ValidateRange(1,256)] [int] $Max=32
    )
    process {
        $arguments = @('history',$Release,'-o','json',"--max=$Max")
        if ($Namespace) { $arguments += @('--namespace',$Namespace) }
        foreach ($entry in @(Invoke-HelmJson -ArgumentList $arguments)) {
            [pscustomobject]@{
                PSTypeName  = 'KubeShell.HelmRevision'
                Release     = $Release
                Namespace   = $Namespace
                Revision    = [int]$entry.revision
                Updated     = [string]$entry.updated
                Status      = [string]$entry.status
                Chart       = [string]$entry.chart
                AppVersion  = [string]$entry.app_version
                Description = [string]$entry.description
                Raw         = $entry
            }
        }
    }
}

function Get-KubeHelmStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [Alias('Name')] [string] $Release,
        [string] $Namespace
    )
    process {
        $arguments = @('status',$Release,'-o','json')
        if ($Namespace) { $arguments += @('--namespace',$Namespace) }
        $status = Invoke-HelmJson -ArgumentList $arguments
        if ($null -eq $status) { return }
        $status.PSObject.TypeNames.Insert(0,'KubeShell.HelmStatus')
        $status
    }
}

Export-ModuleMember -Function @(
    'Get-KubeHelmRelease','Get-KubeHelmValue','Get-KubeHelmHistory','Get-KubeHelmStatus'
)
