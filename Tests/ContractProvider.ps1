[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Contract([bool]$Condition, [string]$Id, [string]$Message) {
    if (-not $Condition) { throw "[$Id] $Message" }
}
function Assert-Failure([scriptblock]$Action, [string]$Id, [string]$Message) {
    try { & $Action; throw "[$Id] $Message" } catch { if ($_.Exception.Message -eq "[$Id] $Message") { throw } }
}
function Remove-DriveIfPresent([string]$Name) {
    if (Get-PSDrive -Name $Name -ErrorAction SilentlyContinue) { Remove-PSDrive -Name $Name -Force -ErrorAction SilentlyContinue }
}

# Build/load exactly the production Provider boundary. The Provider resolves adapters from its
# repository-local Hosting root, so the contract fixture mirrors a minimal temporary repository and
# places its semantic managed backend at the production relative adapter path. Source build outputs
# remain untouched; no production routing hook or test-only Host option is added.
& (Join-Path $Root 'Runtime/KubeShell.Runtime/build.ps1') | Out-Null
& (Join-Path $Root 'ObjectModel/KubeShell.ObjectModel/build.ps1') | Out-Null
& (Join-Path $Root 'Hosting/KubeShell.Hosting/build.ps1') | Out-Null
& (Join-Path $Root 'Optional/KubeShell.Provider/build.ps1') | Out-Null
$fixtureProject = Join-Path $PSScriptRoot 'Fixtures/KubeShell.Tests.ProviderBackend/KubeShell.Tests.ProviderBackend.csproj'
$fixtureOutput = @(& dotnet build $fixtureProject -c Release 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Provider backend fixture build failed:`n$($fixtureOutput -join [Environment]::NewLine)" }

$runtimeDll = Join-Path $Root 'Runtime/KubeShell.Runtime/bin/Release/net8.0/KubeShell.Runtime.dll'
$objectDll = Join-Path $Root 'ObjectModel/KubeShell.ObjectModel/bin/Release/net8.0/KubeShell.ObjectModel.dll'
$hostingDll = Join-Path $Root 'Hosting/KubeShell.Hosting/bin/Release/net8.0/KubeShell.Hosting.dll'
$fixtureDll = Join-Path $PSScriptRoot 'Fixtures/KubeShell.Tests.ProviderBackend/bin/Release/net8.0/KubeShell.Tests.ProviderBackend.dll'
foreach ($dll in @($runtimeDll,$objectDll,$hostingDll)) { [Reflection.Assembly]::LoadFrom($dll) | Out-Null }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('kubeshell-provider-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

# Mirror only the repository structure that Provider/Hosting need for root discovery. The test
# adapter is repository-local at the exact production relative path, while Runtime/ObjectModel/Hosting
# are already loaded from their production builds above. This keeps source build outputs untouched.
$fixtureRoot = Join-Path $temp 'repository'
$providerModuleRoot = Join-Path $fixtureRoot 'Optional/KubeShell.Provider'
$providerBin = Join-Path $providerModuleRoot 'bin/Release/net8.0'
$managedBackendDirectory = Join-Path $fixtureRoot 'Backends/KubeShell.KubernetesClient/bin/Release/net8.0'
foreach ($directory in @(
    (Join-Path $fixtureRoot 'Runtime/KubeShell.Runtime'),
    $providerBin,
    $managedBackendDirectory
)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $Root 'Optional/KubeShell.Provider/KubeShell.Provider.psd1') -Destination (Join-Path $providerModuleRoot 'KubeShell.Provider.psd1') -Force
Copy-Item -LiteralPath (Join-Path $Root 'Optional/KubeShell.Provider/bin/Release/net8.0/KubeShell.Provider.dll') -Destination (Join-Path $providerBin 'KubeShell.Provider.dll') -Force
Copy-Item -LiteralPath $fixtureDll -Destination (Join-Path $managedBackendDirectory 'KubeShell.KubernetesClient.dll') -Force
$providerManifest = Join-Path $providerModuleRoot 'KubeShell.Provider.psd1'
$previousKubeConfig = $env:KUBECONFIG
$previousConfigHome = $env:KUBESHELL_CONFIG_HOME
try {
    $fakeConfig = Join-Path $temp 'config'
    Set-Content -LiteralPath $fakeConfig -Value '# fixture' -NoNewline
    $env:KUBECONFIG = $fakeConfig
    $env:KUBESHELL_CONFIG_HOME = $temp
    @{
        version = 1
        configSets = @(
            @{ name='fixture'; paths=@($fakeConfig) },
            @{ name='exact-paths'; paths=@(' ', ($fakeConfig + ' '), (' ' + $fakeConfig)) }
        )
        profiles = @(
            @{ name='prod'; configSet='fixture'; context=$null; namespace='default' },
            @{ name='exact-paths'; configSet='exact-paths'; context=$null; namespace='default' }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temp 'configuration.json')

    Import-Module $providerManifest -Force
    [KubeShell.Backends.KubernetesClient.FixtureState]::Reset()

    # B1 regression: named config-set paths are execution identity and must reach Runtime/backend
    # literally. Whitespace-only and leading/trailing-space Unix filenames are not "missing" paths.
    Remove-DriveIfPresent ExactPaths
    [KubeShell.Backends.KubernetesClient.FixtureState]::LastConfigViewPaths = [string[]]@()
    New-PSDrive -Name ExactPaths -PSProvider Kube -Root 'profile:exact-paths' | Out-Null
    $exactPaths = [KubeShell.Backends.KubernetesClient.FixtureState]::LastConfigViewPaths
    Assert-Contract ($exactPaths.Count -eq 3) B1 'Provider loader changed config-set path cardinality.'
    Assert-Contract ($exactPaths[0] -ceq ' ') B1 'Provider loader discarded or trimmed a whitespace-only kubeconfig filename.'
    Assert-Contract ($exactPaths[1] -ceq ($fakeConfig + ' ')) B1 'Provider loader trimmed trailing whitespace from a kubeconfig filename.'
    Assert-Contract ($exactPaths[2] -ceq (' ' + $fakeConfig)) B1 'Provider loader trimmed leading whitespace from a kubeconfig filename.'

    # C1-C10 / K1/K4: exercise every mount truth-table branch through New-PSDrive dynamic parameters.
    Remove-DriveIfPresent T
    New-PSDrive -Name T -PSProvider Kube -Root fixture-context | Out-Null
    Assert-Contract ((Get-Item 'T:\').Context -eq 'fixture-context') C1 'Target-root mount failed.'

    # Regression guard for provider-path translation. PSDriveInfo.Root is embedded in
    # provider-internal paths; a context containing '/' must remain one semantic root.
    Remove-DriveIfPresent Slash
    New-PSDrive -Name Slash -PSProvider Kube -Root 'team/fixture-context' | Out-Null
    Assert-Contract ((Get-Item 'Slash:\').Context -eq 'team/fixture-context') C1 'Slash-containing target root was not translated to the drive root.'
    Assert-Contract ((Get-Item 'Slash:\Namespaces').Name -eq 'Namespaces') C1 'Drive-root prefix was not removed before child traversal.'

    Remove-DriveIfPresent N
    New-PSDrive -Name N -PSProvider Kube -Root fixture-context -Namespace default | Out-Null
    Assert-Contract ((Get-Item 'N:\').Namespace -eq 'default') C2 'Namespace mount failed.'

    Remove-DriveIfPresent P
    New-PSDrive -Name P -PSProvider Kube -Root fixture-context -Namespace default -Resource pods | Out-Null
    $podRoot = Get-Item 'P:\'
    Assert-Contract ($podRoot.Resource -eq 'pods') C3 'Explicit resource collection mount failed.'
    Assert-Contract ($podRoot.Kind -eq 'Pod') C3 'Resource collection projection lost Kind metadata.'
    Assert-Contract ($podRoot.ApiVersion -eq 'v1') C3 'Resource collection projection lost ApiVersion metadata.'

    Remove-DriveIfPresent PA
    New-PSDrive -Name PA -PSProvider Kube -Root fixture-context -Resource pods -AllNamespaces | Out-Null
    $allNamespaceBuckets = @(Get-ChildItem 'PA:\')
    Assert-Contract ($allNamespaceBuckets.Count -ge 1) C4 'AllNamespaces mount failed.'
    Assert-Contract ($allNamespaceBuckets[0].Resource -eq 'pods') C4 'AllNamespaces bucket projection lost Resource identity.'
    Assert-Contract ($allNamespaceBuckets[0].Kind -eq 'Pod') C4 'AllNamespaces bucket projection lost Kind metadata.'
    Assert-Contract ($allNamespaceBuckets[0].ApiVersion -eq 'v1') C4 'AllNamespaces bucket projection lost ApiVersion metadata.'
    Assert-Failure { New-PSDrive -Name Bad5 -PSProvider Kube -Root fixture-context -Resource pods -ErrorAction Stop | Out-Null } C5 'Namespaced resource without scope was accepted.'

    Remove-DriveIfPresent Nodes
    New-PSDrive -Name Nodes -PSProvider Kube -Root fixture-context -Resource nodes | Out-Null
    $nodeRoot = Get-Item 'Nodes:\'
    Assert-Contract ($nodeRoot.Resource -eq 'nodes') C6 'Cluster collection mount failed.'
    Assert-Contract ($nodeRoot.Kind -eq 'Node') C6 'Cluster collection projection lost Kind metadata.'
    Assert-Contract ($nodeRoot.ApiVersion -eq 'v1') C6 'Cluster collection projection lost ApiVersion metadata.'
    Assert-Failure { New-PSDrive -Name Bad7 -PSProvider Kube -Root fixture-context -Namespace default -Resource nodes -ErrorAction Stop | Out-Null } C7 'Cluster resource accepted namespace.'
    Assert-Failure { New-PSDrive -Name Bad8 -PSProvider Kube -Root fixture-context -Resource nodes -AllNamespaces -ErrorAction Stop | Out-Null } C8 'Cluster resource accepted AllNamespaces.'
    Assert-Failure { New-PSDrive -Name Bad9 -PSProvider Kube -Root fixture-context -AllNamespaces -ErrorAction Stop | Out-Null } C9 'AllNamespaces without resource was accepted.'
    Assert-Failure { New-PSDrive -Name Bad10 -PSProvider Kube -Root fixture-context -Namespace default -Resource pods -AllNamespaces -ErrorAction Stop | Out-Null } C10 'Namespace and AllNamespaces were accepted together.'

    # C11: profile without explicit context freezes the current context at mount time.
    Remove-DriveIfPresent Profile
    [KubeShell.Backends.KubernetesClient.FixtureState]::CurrentContext = 'fixture-context'
    New-PSDrive -Name Profile -PSProvider Kube -Root 'profile:prod' | Out-Null
    [KubeShell.Backends.KubernetesClient.FixtureState]::CurrentContext = 'other-context'
    Assert-Contract ((Get-Item 'Profile:\').Context -eq 'fixture-context') C11 'Mounted drive followed later ambient current-context change.'

    # E10/J4/J5/J6: Test-Path uses point GET, maps NotFound=false and preserves other Runtime errors.
    [KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls = 0
    [KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls = 0
    Assert-Contract (Test-Path 'P:\shared') E10 'Test-Path failed for existing item.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq 1) E10 'PowerShell path normalization performed a hidden point-read before ItemExists.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls -eq 0) E10 'Test-Path listed the collection.'
    Assert-Contract (-not (Test-Path 'P:\missing')) J4 'NotFound did not map to false.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq 2) J4 'Missing-path resolution performed a hidden point-read before ItemExists.'
    function Get-EffectiveRuntimeErrorRecord([System.Management.Automation.ErrorRecord]$Record) {
        $current = $Record
        for ($depth = 0; $depth -lt 8; $depth++) {
            if ($current.FullyQualifiedErrorId -match '^KubeShell\.Runtime\.') { return $current }

            $exception = $current.Exception
            if ($null -eq $exception) { break }
            $property = $exception.PSObject.Properties['ErrorRecord']
            if ($null -eq $property -or $property.Value -isnot [System.Management.Automation.ErrorRecord]) { break }

            $next = [System.Management.Automation.ErrorRecord]$property.Value
            if ([object]::ReferenceEquals($current, $next)) { break }
            $current = $next
        }
        return $current
    }
    function Assert-ProviderFailure([scriptblock]$Action, [string]$Kind, [string]$Category, [string]$Case) {
        try { & $Action; throw "[$Case] expected Provider failure was swallowed." }
        catch {
            if ($_.Exception.Message -eq "[$Case] expected Provider failure was swallowed.") { throw }
            $record = Get-EffectiveRuntimeErrorRecord $_
            Assert-Contract ($record.FullyQualifiedErrorId -match ("KubeShell\.Runtime\." + [regex]::Escape($Kind))) J3 "Runtime ErrorId was not preserved for $Case (actual: $($record.FullyQualifiedErrorId))."
            Assert-Contract ($record.CategoryInfo.Category.ToString() -eq $Category) J6 "$Kind did not map to $Category (actual: $($record.CategoryInfo.Category))."
        }
    }
    # First verify the Provider's native non-terminating error record without Stop escalation.
    # This proves J3/J6 at the public error-stream boundary; the checks below then verify that
    # ErrorAction Stop does not hide the same Runtime record behind ActionPreferenceStopException.
    $directRuntimeErrors = @()
    $beforeAuthenticationGet = [KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls
    $directResult = Test-Path 'P:\unauthenticated' -ErrorAction Continue -ErrorVariable directRuntimeErrors
    Assert-Contract (-not $directResult) J5 'Authentication failure unexpectedly reported that the item exists.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq ($beforeAuthenticationGet + 1)) J5 'Authentication path normalization performed a hidden point-read before ItemExists.'
    Assert-Contract ($directRuntimeErrors.Count -ge 1) J3 'Provider emitted no Runtime error record for authentication.'
    $directRecord = Get-EffectiveRuntimeErrorRecord $directRuntimeErrors[-1]
    Assert-Contract ($directRecord.FullyQualifiedErrorId -match 'KubeShell\.Runtime\.Authentication') J3 "Provider error stream lost Runtime ErrorId for authentication (actual: $($directRecord.FullyQualifiedErrorId))."
    Assert-Contract ($directRecord.CategoryInfo.Category.ToString() -eq 'SecurityError') J6 "Authentication did not map to SecurityError (actual: $($directRecord.CategoryInfo.Category))."

    # Slash-containing context roots are covered above through real target-root navigation.
    # Resource error mapping is validated on P:, where the path is unambiguously a resource item.

    Assert-ProviderFailure { $null = Test-Path 'P:\unauthenticated' -ErrorAction Stop } 'Authentication' 'SecurityError' 'authentication'
    Assert-ProviderFailure { $null = Test-Path 'P:\forbidden' -ErrorAction Stop } 'Authorization' 'PermissionDenied' 'authorization'
    Assert-ProviderFailure { $null = Test-Path 'P:\unavailable' -ErrorAction Stop } 'Unavailable' 'ResourceUnavailable' 'unavailable'
    try { $null = Test-Path 'P:\forbidden' -PathType Container -ErrorAction Stop; throw '[J5] IsItemContainer authorization failure was swallowed.' }
    catch {
        if ($_.Exception.Message -eq '[J5] IsItemContainer authorization failure was swallowed.') { throw }
        $record = Get-EffectiveRuntimeErrorRecord $_
        Assert-Contract ($record.FullyQualifiedErrorId -match 'KubeShell\.Runtime\.Authorization') J5 "IsItemContainer lost non-NotFound Runtime failure (actual: $($record.FullyQualifiedErrorId))."
    }

    # Provider-side wildcard expansion is required so exact destructive paths can bypass
    # PowerShell's engine-side ItemExists preflight while wildcard paths still expand correctly.
    $beforeWildcardListTrace = [KubeShell.Backends.KubernetesClient.FixtureState]::ListRequests.Count
    $beforeWildcardGetTrace = [KubeShell.Backends.KubernetesClient.FixtureState]::GetRequests.Count
    $wildcardItems = @(Get-Item 'P:\sh*')
    Assert-Contract ($wildcardItems.Count -eq 1 -and $wildcardItems[0].Name -eq 'shared') K3 'Provider-side wildcard expansion did not resolve the mounted resource collection.'

    # PowerShell may resolve a wildcard provider path more than once while preparing and executing
    # one command. K3 constrains semantic traversal, not engine callback multiplicity: every request
    # caused by this wildcard must remain under P:'s RootLocator (pods/default), and the materialized
    # point GET must remain the matched item in that same collection.
    $wildcardListRequests = @([KubeShell.Backends.KubernetesClient.FixtureState]::ListRequests | Select-Object -Skip $beforeWildcardListTrace)
    $wildcardGetRequests = @([KubeShell.Backends.KubernetesClient.FixtureState]::GetRequests | Select-Object -Skip $beforeWildcardGetTrace)
    Assert-Contract ($wildcardListRequests.Count -ge 1) K3 'Wildcard expansion did not enumerate the mounted resource collection.'
    Assert-Contract (@($wildcardListRequests | Where-Object { $_ -ne '|pods|Explicit|default|' }).Count -eq 0) K3 "Wildcard traversal escaped the P: RootLocator: $($wildcardListRequests -join ', ')."
    Assert-Contract ($wildcardGetRequests.Count -ge 1) K3 'Wildcard-expanded Get-Item did not materialize the matched item.'
    Assert-Contract (@($wildcardGetRequests | Where-Object { $_ -ne '|pods|Explicit|default|shared' }).Count -eq 0) K3 "Wildcard point traversal escaped the P: RootLocator: $($wildcardGetRequests -join ', ')."

    # E11/H1-H5/H11/H12/K9: provider CRUD/ShouldProcess/Force/wire projection.
    [KubeShell.Backends.KubernetesClient.FixtureState]::Reset()
    $payload = '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"created","namespace":"default"}}'
    $warnings = @()
    $created = New-Item 'P:\created' -Value $payload -WarningVariable warnings
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::CreateCalls -eq 1) H1 'New-Item did not perform atomic Create.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq 0) H1 'New-Item performed a read preflight.'
    Assert-Contract ($warnings.Count -ge 1) H12 'Provider lost Runtime warning.'

    New-Item 'P:\forced' -Value '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"forced","namespace":"default"}}' -Force | Out-Null
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::ApplyCalls -eq 1) H2 'New-Item -Force did not map to Apply.'

    Set-Item 'P:\shared' -Value '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"shared","namespace":"default"}}'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::ApplyCalls -eq 2) H3 'Set-Item did not map to Apply.'
    $failureWarnings = @()
    try {
        Set-Item 'P:\conflict' -Value '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"conflict","namespace":"default"}}' -WarningVariable failureWarnings -ErrorAction Stop
        throw '[H12] expected conflict failure was swallowed.'
    }
    catch {
        if ($_.Exception.Message -eq '[H12] expected conflict failure was swallowed.') { throw }
        $record = Get-EffectiveRuntimeErrorRecord $_
        Assert-Contract ($record.FullyQualifiedErrorId -match 'KubeShell\.Runtime\.Conflict') J3 "Conflict Runtime ErrorId was not preserved (actual: $($record.FullyQualifiedErrorId))."
        Assert-Contract ($record.CategoryInfo.Category.ToString() -eq 'ResourceBusy') J6 "Conflict did not map to ResourceBusy (actual: $($record.CategoryInfo.Category))."
        Assert-Contract ($failureWarnings.Count -ge 1) H12 'Provider lost Runtime warning on failure.'
    }

    $beforeDelete = [KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls
    $beforeGet = [KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls
    $beforeList = [KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls
    Remove-Item 'P:\shared' -Confirm:$false
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls -eq $beforeDelete + 1) H4 'Remove-Item did not map to Delete.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq $beforeGet) E11 'Remove-Item performed a point-read preflight.'
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls -eq $beforeList) E11 'Remove-Item performed a list preflight.'

    $c0=[KubeShell.Backends.KubernetesClient.FixtureState]::CreateCalls; $a0=[KubeShell.Backends.KubernetesClient.FixtureState]::ApplyCalls; $d0=[KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls
    $whatIfGet0=[KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls; $whatIfList0=[KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls
    New-Item 'P:\whatif' -Value '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"whatif","namespace":"default"}}' -WhatIf | Out-Null
    Set-Item 'P:\shared' -Value '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"shared","namespace":"default"}}' -WhatIf
    Remove-Item 'P:\shared' -WhatIf
    Assert-Contract (([KubeShell.Backends.KubernetesClient.FixtureState]::CreateCalls -eq $c0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::ApplyCalls -eq $a0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls -eq $d0)) H5 'WhatIf crossed mutation boundary.'
    Assert-Contract (([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq $whatIfGet0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls -eq $whatIfList0)) E11 'WhatIf delete path performed a read/list preflight.'

    # Exercise the all-namespaces bucket and cluster-scoped resource-leaf shapes as well;
    # HasChildItems must classify both structurally before Remove-Item reaches ShouldProcess.
    $bucketGet0=[KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls; $bucketList0=[KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls; $bucketDelete0=[KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls
    Remove-Item 'PA:\default\shared' -WhatIf
    Assert-Contract (([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq $bucketGet0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls -eq $bucketList0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls -eq $bucketDelete0)) E11 'AllNamespaces item delete performed a read/list preflight or crossed WhatIf.'

    $nodeGet0=[KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls; $nodeList0=[KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls
    Assert-Failure { Remove-Item 'Nodes:\node-a' -Confirm:$false -ErrorAction Stop } H11 'Node delete succeeded without Force.'
    Assert-Contract (([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq $nodeGet0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls -eq $nodeList0)) E11 'Node delete policy check performed a read/list preflight.'
    $d0=[KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls
    Remove-Item 'Nodes:\node-a' -Force -Confirm:$false
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::DeleteCalls -eq $d0 + 1) H11 'Node delete with Force did not execute.'
    Assert-Contract (([KubeShell.Backends.KubernetesClient.FixtureState]::GetCalls -eq $nodeGet0) -and ([KubeShell.Backends.KubernetesClient.FixtureState]::ListCalls -eq $nodeList0)) E11 'Forced node delete performed a read/list preflight.'

    $item = Get-Item 'P:\shared'
    Assert-Contract ($item.Name -eq 'shared') K9 'Round-trip presentation lost metadata.name.'
    Assert-Contract ($item.Namespace -eq 'default') K9 'Round-trip presentation lost metadata.namespace.'
    Assert-Contract ($item.Kind -eq 'Pod') K9 'Round-trip presentation lost Kubernetes kind.'
    Assert-Contract ($item.ApiVersion -eq 'v1') K9 'Round-trip presentation lost Kubernetes apiVersion.'
    $raw = $item.RawJson | ConvertFrom-Json -Depth 20
    Assert-Contract ($raw.kind -eq 'Pod') K9 'Fixture GET response RawJson disagreed with descriptor kind.'
    Assert-Contract ($raw.apiVersion -eq 'v1') K9 'Fixture GET response RawJson disagreed with descriptor apiVersion.'
    Assert-Contract (($raw.metadata.name -eq 'shared') -and ($raw.metadata.namespace -eq 'default')) K9 'Fixture GET response RawJson lost object identity.'
    $beforeRoundTripApply = [KubeShell.Backends.KubernetesClient.FixtureState]::ApplyCalls
    Set-Item 'P:\shared' -Value $item
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::ApplyCalls -eq $beforeRoundTripApply + 1) K9 'Presentation-object round-trip did not map back to Apply.'
    $wire=[KubeShell.Backends.KubernetesClient.FixtureState]::LastPayloadJson
    Assert-Contract ($wire -notmatch 'Context|Node|RawJson|Resource"') K9 'Presentation fields leaked into wire JSON.'

    # F4-F6/K3/K4/K6/K7: framework traversal and refresh surfaces.
    $beforeDiscovery=[KubeShell.Backends.KubernetesClient.FixtureState]::DiscoveryCalls
    $null = Get-ChildItem 'N:\' -Refresh
    Assert-Contract ([KubeShell.Backends.KubernetesClient.FixtureState]::DiscoveryCalls -gt $beforeDiscovery) F4 'Refresh did not rematerialize namespace topology.'
    $null = Get-ChildItem 'T:\Namespaces\default' -Refresh
    Assert-Contract ($true) F5 'Deep refresh failed.'
    $null = Get-ChildItem 'P:\' -Refresh
    Assert-Contract ($true) F6 'Target-container refresh failed.'
    Assert-Failure { New-PSDrive -Name Leaf -PSProvider Kube -Root fixture-context -Namespace default -Resource 'pods/shared' -ErrorAction Stop | Out-Null } K5 'Leaf-root mount became expressible through Provider dynamic parameters.'
    Assert-Failure { Get-ChildItem 'P:\' -Recurse -ErrorAction Stop | Out-Null } K6 'Recursive traversal was accepted.'
    $secure = ConvertTo-SecureString 'x' -AsPlainText -Force
    $cred = [pscredential]::new('fixture',$secure)
    Assert-Failure { New-PSDrive -Name Cred -PSProvider Kube -Root fixture-context -Credential $cred -ErrorAction Stop | Out-Null } K7 'PSCredential was silently accepted.'

    Write-Output 'MATRIX_IDS:P=C1,C2,C3,C4,C5,C6,C7,C8,C9,C10,C11,E10,E11,F4,F5,F6,H1,H2,H3,H4,H5,H11,H12,J3,J4,J5,J6,K1,K3,K4,K5,K6,K7,K9'
    Write-Host 'Provider contract fixture passed.'
}
finally {
    foreach ($name in 'T','Slash','N','P','PA','Nodes','Profile','ExactPaths','Bad5','Bad7','Bad8','Bad9','Bad10','Cred','Leaf') { Remove-DriveIfPresent $name }
    Remove-Module KubeShell.Provider -Force -ErrorAction SilentlyContinue
    $env:KUBECONFIG = $previousKubeConfig
    $env:KUBESHELL_CONFIG_HOME = $previousConfigHome
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
