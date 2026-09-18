# Internal implementation for KubeShell.Shell. Loaded into the parent module scope.

function Get-KubeBookmarkStorePath {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:KUBESHELL_CONFIG_HOME)) {
        return Join-Path $env:KUBESHELL_CONFIG_HOME 'bookmarks.json'
    }

    if ($IsWindows) {
        $base = $env:APPDATA
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path $HOME 'AppData/Roaming'
        }
        return Join-Path $base 'KubeShell/bookmarks.json'
    }

    $base = $env:XDG_CONFIG_HOME
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $HOME '.config'
    }
    return Join-Path $base 'kubeshell/bookmarks.json'
}
function Import-KubeBookmarkStore {
    [CmdletBinding()]
    param()

    $script:Bookmarks = @{}
    $path = Get-KubeBookmarkStorePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }

    try {
        $document = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $items = if ($document.PSObject.Properties['bookmarks']) { @($document.bookmarks) } else { @($document) }
        foreach ($item in $items) {
            if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.Name)) { continue }
            $script:Bookmarks[[string]$item.Name] = [pscustomobject]@{
                PSTypeName   = 'KubeShell.Bookmark'
                Name         = [string]$item.Name
                Profile      = [string](Get-KubePropertyValue $item @('Profile'))
                ConfigSet    = [string](Get-KubePropertyValue $item @('ConfigSet'))
                Context      = [string](Get-KubePropertyValue $item @('Context'))
                Namespace    = [string](Get-KubePropertyValue $item @('Namespace'))
                Resource     = [string](Get-KubePropertyValue $item @('Resource'))
                ResourceName = [string](Get-KubePropertyValue $item @('ResourceName'))
            }
        }
    }
    catch {
        Write-Warning "KubeShell could not load bookmark store '$path': $($_.Exception.Message)"
    }
}
function Save-KubeBookmarkStore {
    [CmdletBinding()]
    param()

    $path = Get-KubeBookmarkStorePath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # Write a complete replacement next to the target first. This avoids leaving a
    # partially-written bookmark database if the host is interrupted during serialization.
    $temporaryPath = "$path.$PID.tmp"
    $document = [ordered]@{
        version   = 1
        bookmarks = @(
            $script:Bookmarks.Values |
                Sort-Object Name |
                Select-Object Name,Profile,ConfigSet,Context,Namespace,Resource,ResourceName
        )
    }

    try {
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Import-KubeBookmarkStore
function Set-KubeBookmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)] [string] $Name,
        [string] $Profile,
        [string] $ConfigSet,
        [string] $Context,
        [string] $Namespace,
        [string] $Resource,
        [string] $ResourceName
    )

    $session = Get-KubeSession
    $script:Bookmarks[$Name] = [pscustomobject]@{
        PSTypeName   = 'KubeShell.Bookmark'
        Name         = $Name
        Profile      = $Profile ?? $session.Profile
        ConfigSet    = $ConfigSet ?? $session.ConfigSet
        Context      = $Context ?? $session.Context
        Namespace    = $Namespace ?? $session.Namespace
        Resource     = $Resource
        ResourceName = $ResourceName
    }
    Save-KubeBookmarkStore
    return $script:Bookmarks[$Name]
}
function Get-KubeBookmark {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name) { return $script:Bookmarks[$Name] }
    return $script:Bookmarks.Values | Sort-Object Name
}
function Remove-KubeBookmark {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Low')]
    param([Parameter(Mandatory,Position=0)][string]$Name)
    if ($script:Bookmarks.ContainsKey($Name) -and $PSCmdlet.ShouldProcess($Name,'Remove Kubernetes bookmark')) {
        [void]$script:Bookmarks.Remove($Name)
        Save-KubeBookmarkStore
    }
}
function Use-KubeBookmark {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Name)
    $bookmark = Get-KubeBookmark $Name
    if (-not $bookmark) { throw "Kubernetes bookmark '$Name' does not exist." }

    if (-not [string]::IsNullOrWhiteSpace([string]$bookmark.Profile) -and (Get-KubeProfile $bookmark.Profile)) {
        Use-KubeProfile $bookmark.Profile -Confirm:$false | Out-Null
        if ($bookmark.Context -and $bookmark.Context -ne (Get-KubeSession).Context) { Set-KubeContext $bookmark.Context -Confirm:$false | Out-Null }
        if ($bookmark.Namespace) { Set-KubeNamespace $bookmark.Namespace -Confirm:$false | Out-Null }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$bookmark.ConfigSet) -and (Get-KubeConfigSet $bookmark.ConfigSet)) {
        Use-KubeConfigSet $bookmark.ConfigSet -Context $bookmark.Context -Namespace $bookmark.Namespace -Confirm:$false | Out-Null
    }
    else {
        if ($bookmark.Context) { Set-KubeContext $bookmark.Context -Confirm:$false | Out-Null }
        if ($bookmark.Namespace) { Set-KubeNamespace $bookmark.Namespace -Confirm:$false | Out-Null }
    }
    return $bookmark
}
