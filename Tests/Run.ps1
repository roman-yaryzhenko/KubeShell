[CmdletBinding()]
param(
    [switch] $Integration,
    [string] $Namespace = 'default',
    [switch] $RequirePester,
    [switch] $SkipNodeAudits,
    [Parameter(DontShow)] [switch] $IsolatedProcess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# KubeShell.Runtime is a normal .NET assembly and cannot be unloaded from a live PowerShell
# process. Re-enter the suite in a clean process when an earlier KubeShell import would make
# type-based tests observe a stale Runtime assembly from a previous source build.
$loadedRuntime = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'KubeShell.Runtime' })
if (-not $IsolatedProcess -and $loadedRuntime.Count -gt 0) {
    $pwsh = Get-Command pwsh -ErrorAction Stop
    $arguments = @('-NoProfile', '-File', $PSCommandPath, '-IsolatedProcess')
    if ($Integration) { $arguments += '-Integration' }
    if ($RequirePester) { $arguments += '-RequirePester' }
    if ($SkipNodeAudits) { $arguments += '-SkipNodeAudits' }
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) { $arguments += @('-Namespace', $Namespace) }

    & $pwsh.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Isolated KubeShell test process failed with exit code $LASTEXITCODE."
    }
    return
}

function Reset-KubeShellTestModules {
    [CmdletBinding()]
    param()

    # Root and nested modules are deliberately removed between Pester containers.
    # This keeps Pester's -ModuleName resolution deterministic even though the
    # production module graph imports Core/Resources into several module scopes.
    $loaded = @(Get-Module -All | Where-Object Name -Like 'KubeShell*')
    if ($loaded.Count -eq 0) { return }

    foreach ($module in @($loaded | Where-Object Name -EQ 'KubeShell')) {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
    foreach ($module in @($loaded | Where-Object Name -NE 'KubeShell')) {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
}

& (Join-Path $PSScriptRoot 'Parse.ps1')
& (Join-Path $PSScriptRoot 'Smoke.ps1')
& (Join-Path $PSScriptRoot 'Runtime.ps1')

if (-not $SkipNodeAudits) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        foreach ($audit in @(
            @{ File='KubectlProtocolAudit.mjs'; Label='Kubectl IPC protocol audit' },
            @{ File='BackendRoutingAudit.mjs'; Label='Backend routing architecture audit' },
            @{ File='ProviderObjectModelAudit.mjs'; Label='Provider/ObjectModel architecture audit' },
            @{ File='PackageAudit.mjs'; Label='Package reproducibility audit' }
        )) {
            & $node.Source (Join-Path $PSScriptRoot $audit.File) (Split-Path -Parent $PSScriptRoot)
            if ($LASTEXITCODE -ne 0) { throw "$($audit.Label) failed with exit code $LASTEXITCODE." }
        }
    }
    else {
        Write-Warning 'Node.js is not available; supplemental cross-language/source audits were skipped.'
    }
}

# The optional managed backend references Runtime interfaces directly. Rebuild it from
# source before Pester whenever the SDK is available so an older bin/Release assembly
# cannot satisfy file-existence checks while carrying a stale Runtime ABI.
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    & (Join-Path $PSScriptRoot '../Backends/KubeShell.KubernetesClient/build.ps1') | Out-Null
    # Hosting activates the optional Go-backed adapter by reflection. Rebuild its managed
    # adapter assembly as well so a stale bin/Release DLL cannot preserve an older constructor ABI.
    # The native Go host is not required for this source/test rebuild.
    & (Join-Path $PSScriptRoot '../Backends/KubeShell.Kubectl/build.ps1') | Out-Null
    $objectModelFixtureOutput = @(
        & $dotnet.Source run --project (Join-Path $PSScriptRoot 'Fixtures/KubeShell.Tests.ObjectModelFixture/KubeShell.Tests.ObjectModelFixture.csproj') -c Release 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw "ObjectModel cluster-free fixture failed with exit code ${LASTEXITCODE}:`n$($objectModelFixtureOutput -join [Environment]::NewLine)"
    }
    if ($objectModelFixtureOutput.Count -gt 0) {
        $objectModelFixtureOutput | Write-Output
    }
}

# Smoke/Runtime intentionally import modules. Pester module-targeted mocks need a
# clean module graph, especially on Pester 6 where duplicate names are rejected.
Reset-KubeShellTestModules

$pester = Get-Module Pester -ListAvailable |
    Where-Object Version -GE ([version]'5.5.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($pester) {
    Import-Module $pester.Path -Force

    $testFiles = @(
        'Core.Tests.ps1',
        'RuntimeAssembly.Tests.ps1',
        'ContractEvidence.Tests.ps1',
        'BackendRouting.Tests.ps1',
        'ManagedBackend.Source.Tests.ps1',
        'KubectlHostBackend.Source.Tests.ps1',
        'EmbeddedKubectlHost.Tests.ps1',
        'KubeShell.Tests.ps1',
        'Configuration.Tests.ps1',
        'MockTransport.Tests.ps1',
        'OptionalModules.Tests.ps1'
    ) | ForEach-Object { Join-Path $PSScriptRoot $_ }

    $failedCount = 0
    foreach ($testFile in $testFiles) {
        Reset-KubeShellTestModules

        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $testFile
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Detailed'

        $result = Invoke-Pester -Configuration $configuration
        $failedCount += $result.FailedCount
    }

    Reset-KubeShellTestModules
    if ($failedCount -gt 0) {
        throw "Pester reported $failedCount failed test(s)."
    }
}
elseif ($RequirePester) {
    throw 'Pester 5.5+ is required by -RequirePester but is not installed.'
}
else {
    Write-Warning 'Pester 5.5+ is not installed; unit and mocked-transport suites were skipped.'
}

if ($Integration) {
    # Integration.ps1 is read-only but still talks to the current kubectl context.
    $previous = $env:KUBESHELL_RUN_INTEGRATION
    try {
        $env:KUBESHELL_RUN_INTEGRATION = '1'
        & (Join-Path $PSScriptRoot 'Integration.ps1') -Namespace $Namespace
    }
    finally {
        $env:KUBESHELL_RUN_INTEGRATION = $previous
    }
}

Write-Host 'KubeShell test run completed.'
