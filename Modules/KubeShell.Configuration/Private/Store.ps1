# Internal implementation for KubeShell.Configuration. Loaded into the parent module scope.

function Get-KubeConfigurationStorePath {
    [CmdletBinding()]
    param()

    # Configuration persistence belongs to the PowerShell adapter layer. Runtime only owns the
    # immutable profile/config-set representations and target-resolution policy.
    if (-not [string]::IsNullOrWhiteSpace($env:KUBESHELL_CONFIG_HOME)) {
        return Join-Path $env:KUBESHELL_CONFIG_HOME 'configuration.json'
    }

    if ($IsWindows) {
        $base = $env:APPDATA
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) 'AppData/Roaming'
        }
        return Join-Path $base 'KubeShell/configuration.json'
    }

    $base = $env:XDG_CONFIG_HOME
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.config'
    }
    Join-Path $base 'kubeshell/configuration.json'
}
function Resolve-KubeConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)] [string] $Path,
        [switch] $AllowMissing
    )

    process {
        if ([string]::IsNullOrEmpty($Path)) { throw 'Kubeconfig path cannot be empty.' }
        if (-not $AllowMissing -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Kubeconfig '$Path' does not exist."
        }

        if (Test-Path -LiteralPath $Path) {
            return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        }
        return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    }
}
function ConvertTo-KubeConfigSetObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item)

    $state = Get-KubeExecutionContext
    [pscustomobject]@{
        PSTypeName = 'KubeShell.ConfigSet'
        Name       = [string]$Item.Name
        Paths      = @($Item.Paths)
        Active     = [string]$state.ConfigSet -eq [string]$Item.Name
    }
}
function ConvertTo-KubeProfileObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item)

    $state = Get-KubeExecutionContext
    [pscustomobject]@{
        PSTypeName = 'KubeShell.Profile'
        Name       = [string]$Item.Name
        ConfigSet  = [string]$Item.ConfigSet
        Context    = if ([string]::IsNullOrEmpty([string]$Item.Context)) { $null } else { [string]$Item.Context }
        Namespace  = if ([string]::IsNullOrWhiteSpace([string]$Item.Namespace)) { $null } else { [string]$Item.Namespace }
        Active     = [string]$state.Profile -eq [string]$Item.Name
    }
}
function Import-KubeConfigurationStore {
    [CmdletBinding()]
    param()

    $script:ConfigSets = @{}
    $script:Profiles = @{}
    $path = Get-KubeConfigurationStorePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }

    try {
        $document = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        foreach ($item in @($document.configSets)) {
            if ([string]::IsNullOrWhiteSpace([string]$item.name)) { continue }
            $script:ConfigSets[[string]$item.name] = [KubeShell.Runtime.KubeConfigSet]::new(
                [string]$item.name,
                [string[]]@($item.paths | ForEach-Object { [string]$_ })
            )
        }
        foreach ($item in @($document.profiles)) {
            if ([string]::IsNullOrWhiteSpace([string]$item.name)) { continue }
            $script:Profiles[[string]$item.name] = [KubeShell.Runtime.KubeProfile]::new(
                [string]$item.name,
                [string]$item.configSet,
                $(if ([string]::IsNullOrEmpty([string]$item.context)) { $null } else { [string]$item.context }),
                $(if ([string]::IsNullOrWhiteSpace([string]$item.namespace)) { $null } else { [string]$item.namespace })
            )
        }
    }
    catch {
        Write-Warning "KubeShell could not load configuration store '$path': $($_.Exception.Message)"
    }
}
function Save-KubeConfigurationStore {
    [CmdletBinding()]
    param()

    $path = Get-KubeConfigurationStorePath
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }

    # Serialize a plain adapter-owned DTO rather than teaching Runtime about JSON or the file system.
    $document = [ordered]@{
        version = 1
        configSets = @(
            $script:ConfigSets.Values | Sort-Object Name | ForEach-Object {
                [ordered]@{ name = [string]$_.Name; paths = [string[]]@($_.Paths) }
            }
        )
        profiles = @(
            $script:Profiles.Values | Sort-Object Name | ForEach-Object {
                [ordered]@{
                    name = [string]$_.Name
                    configSet = [string]$_.ConfigSet
                    context = if ([string]::IsNullOrEmpty([string]$_.Context)) { $null } else { [string]$_.Context }
                    namespace = if ([string]::IsNullOrWhiteSpace([string]$_.Namespace)) { $null } else { [string]$_.Namespace }
                }
            }
        )
    }

    # Keep the temporary file beside the destination so the final rename stays on one filesystem.
    $temporaryPath = "$path.$PID.tmp"
    try {
        $document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}
