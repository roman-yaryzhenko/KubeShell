[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MatrixPath,
    [Parameter(Mandatory)][hashtable] $Evidence,
    [string[]] $AllowedUnverified = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
    throw "Frozen contract matrix was not found: $MatrixPath"
}

$knownLanes = @('S','F','P','B')
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($line in Get-Content -LiteralPath $MatrixPath) {
    if ($line -notmatch '^\|\s*(?<id>[A-L]\d+)\s*\|') { continue }
    $id = $Matches.id
    $columns = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    if ($columns.Count -lt 4) { throw "Malformed matrix row for ${id}: $line" }
    $evidenceText = $columns[$columns.Count - 2]
    $required = @($evidenceText.Split('+', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() })
    foreach ($lane in $required) {
        if ($lane -notin $knownLanes) { throw "Matrix row $id uses unknown required evidence lane '$lane'." }
    }
    $missing = @($required | Where-Object {
        -not $Evidence.ContainsKey($_) -or $null -eq $Evidence[$_] -or $id -notin @($Evidence[$_])
    })
    $rows.Add([pscustomobject]@{
        Id = $id
        Required = ($required -join '+')
        Status = if ($missing.Count -eq 0) { 'PASS' } else { 'UNVERIFIED' }
        Missing = ($missing -join '+')
    })
}

if ($rows.Count -ne 101) {
    throw "Frozen matrix parser expected 101 contract rows, found $($rows.Count)."
}

$duplicateIds = @($rows | Group-Object Id | Where-Object Count -ne 1)
if ($duplicateIds.Count -gt 0) {
    $duplicateIdNames = @($duplicateIds | ForEach-Object { $_.Name })
    throw "Frozen matrix contains duplicate IDs: $($duplicateIdNames -join ',')"
}

$unverified = @($rows | Where-Object Status -EQ 'UNVERIFIED')
$unverifiedIds = @($unverified | ForEach-Object { $_.Id })
$allowed = @($AllowedUnverified | Sort-Object -Unique)
$unexpected = @($unverified | Where-Object Id -NotIn $allowed)
$staleAllowance = @($allowed | Where-Object { $_ -notin $unverifiedIds })
if ($staleAllowance.Count -gt 0) {
    throw "AllowedUnverified contains cells that are actually verified: $($staleAllowance -join ','). Remove stale exceptions from the runner."
}
if ($unexpected.Count -gt 0) {
    $detail = $unexpected | ForEach-Object { "$($_.Id)[$($_.Missing)]" }
    throw "Frozen matrix has unexpected UNVERIFIED cells: $($detail -join ', ')"
}

$laneSummary = [ordered]@{}
foreach ($lane in $knownLanes) {
    $requiredIds = @($rows | Where-Object { $_.Required.Split('+') -contains $lane } | ForEach-Object Id)
    $verifiedIds = if ($Evidence.ContainsKey($lane)) { @($Evidence[$lane] | Where-Object { $_ -in $requiredIds } | Sort-Object -Unique) } else { @() }
    $laneSummary[$lane] = "$($verifiedIds.Count)/$($requiredIds.Count)"
}

[pscustomobject]@{
    PSTypeName = 'KubeShell.ContractEvidenceResult'
    MatrixStatus = if ($unverified.Count -eq 0) { 'PASS' } else { 'PARTIAL' }
    TotalCount = $rows.Count
    PassCount = $rows.Count - $unverified.Count
    UnverifiedCount = $unverified.Count
    Unverified = @($unverifiedIds)
    S = $laneSummary.S
    F = $laneSummary.F
    P = $laneSummary.P
    B = $laneSummary.B
    Rows = @($rows)
}
