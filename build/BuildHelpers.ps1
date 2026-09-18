Set-StrictMode -Version Latest

function Invoke-KubeDotNetBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Project,
        [ValidateSet('Debug','Release')][string] $Configuration = 'Release',
        [string[]] $AdditionalArguments = @()
    )

    $dotnet = Get-Command dotnet -ErrorAction Stop
    $arguments = @('build', $Project, '-c', $Configuration) + $AdditionalArguments
    $output = @(& $dotnet.Source @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $diagnostic = $output -join [Environment]::NewLine
        throw "dotnet build failed for '$Project' with exit code ${exitCode}:`n$diagnostic"
    }
    if ($output.Count -gt 0) { $output | Write-Output }
}
