[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'bin'),
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$go = Get-Command go -ErrorAction Stop
$versionText = (& $go.Source version) -join ''
if ($versionText -notmatch 'go(?<version>\d+\.\d+(?:\.\d+)?)') { throw "Cannot parse Go version from '$versionText'." }
$version = [version]$Matches.version
if ($version -lt [version]'1.26.0') { throw "kubeshell-kubectl-host requires Go 1.26 or newer because Kubernetes 1.37 modules declare go 1.26. Found $version." }

$goos = (& $go.Source env GOOS).Trim()
$goarch = (& $go.Source env GOARCH).Trim()
$ridArch = switch ($goarch) {
    'amd64' { 'x64' }
    '386' { 'x86' }
    'arm64' { 'arm64' }
    'arm' { 'arm' }
    default { $goarch }
}
$rid = switch ($goos) {
    'linux' { "linux-$ridArch" }
    'darwin' { "osx-$ridArch" }
    'windows' { "win-$ridArch" }
    default { "$goos-$ridArch" }
}
$extension = if ($goos -eq 'windows') { '.exe' } else { '' }
$output = Join-Path (Join-Path $OutputDirectory $rid) "kubeshell-kubectl-host$extension"
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null

function Invoke-GoVisible {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $FailureLabel
    )

    # The managed backend build captures this script's success stream to obtain the
    # final host path. Route Go's ordinary output to the host UI so test/build
    # diagnostics stay visible instead of being buffered by Select-Object -Last 1.
    & $go.Source @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "$FailureLabel failed with exit code $exitCode." }
}

Push-Location $PSScriptRoot
try {
    Invoke-GoVisible -Arguments @('test', './internal/protocol', './internal/server') -FailureLabel 'go protocol/server tests'
}
finally { Pop-Location }

Push-Location (Join-Path $PSScriptRoot 'host')
try {
    Invoke-GoVisible -Arguments @('test', '-v', './...') -FailureLabel 'go host tests'
    Invoke-GoVisible -Arguments @('build', '-trimpath', '-o', $output, './cmd/kubeshell-kubectl-host') -FailureLabel 'go build'
}
finally { Pop-Location }

Write-Output $output
