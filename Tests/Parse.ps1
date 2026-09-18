[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parseErrors = [Collections.Generic.List[object]]::new()
$files = Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object Extension -In '.ps1','.psm1','.psd1'

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )

    foreach ($parseError in @($errors)) {
        $parseErrors.Add([pscustomobject]@{
            File    = $file.FullName
            Line    = $parseError.Extent.StartLineNumber
            Column  = $parseError.Extent.StartColumnNumber
            Message = $parseError.Message
        })
    }
}

if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-Table -AutoSize | Out-String | Write-Host
    throw "PowerShell parser reported $($parseErrors.Count) error(s)."
}

$formatPath = Join-Path $Root 'Formatting/KubeShell.Format.ps1xml'
[xml](Get-Content -LiteralPath $formatPath -Raw) | Out-Null

Write-Host "Parsed $($files.Count) PowerShell files; formatting XML is well-formed."
