Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:ContractEvidenceScript = Join-Path $PSScriptRoot 'ContractEvidence.ps1'
    $script:ContractMatrixPath = Join-Path $PSScriptRoot '../docs/CONTRACT-VERIFICATION-MATRIX-V1.md'

    function New-CompleteContractEvidence {
        $evidence = @{
            S = @()
            F = @()
            P = @()
            B = @()
        }

        foreach ($line in Get-Content -LiteralPath $script:ContractMatrixPath) {
            if ($line -notmatch '^\|\s*(?<id>[A-L]\d+)\s*\|') { continue }

            $id = $Matches.id
            $columns = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            $required = @(
                $columns[$columns.Count - 2].Split('+', [StringSplitOptions]::RemoveEmptyEntries) |
                    ForEach-Object { $_.Trim() }
            )

            foreach ($lane in $required) {
                $evidence[$lane] = @($evidence[$lane] + $id)
            }
        }

        foreach ($lane in @('S','F','P','B')) {
            $evidence[$lane] = @($evidence[$lane] | Sort-Object -Unique)
        }

        return $evidence
    }
}

Describe 'Frozen contract evidence ledger' {
    It 'reports a complete 101/101 matrix without dereferencing an empty UNVERIFIED collection' {
        $evidence = New-CompleteContractEvidence

        $result = & $script:ContractEvidenceScript `
            -MatrixPath $script:ContractMatrixPath `
            -Evidence $evidence

        $result.MatrixStatus | Should -Be 'PASS'
        $result.TotalCount | Should -Be 101
        $result.PassCount | Should -Be 101
        $result.UnverifiedCount | Should -Be 0
        @($result.Unverified).Count | Should -Be 0
        $result.S | Should -Be '9/9'
        $result.F | Should -Be '76/76'
        $result.P | Should -Be '35/35'
        $result.B | Should -Be '11/11'
    }

    It 'reports the real no-PowerShell-7.4 branch as an allowed 99/101 partial matrix' {
        $evidence = New-CompleteContractEvidence
        $evidence.B = @($evidence.B | Where-Object { $_ -notin @('L2','L4') })

        $result = & $script:ContractEvidenceScript `
            -MatrixPath $script:ContractMatrixPath `
            -Evidence $evidence `
            -AllowedUnverified @('L2','L4')

        $result.MatrixStatus | Should -Be 'PARTIAL'
        $result.TotalCount | Should -Be 101
        $result.PassCount | Should -Be 99
        $result.UnverifiedCount | Should -Be 2
        (@($result.Unverified) -join ',') | Should -Be 'L2,L4'
        $result.S | Should -Be '9/9'
        $result.F | Should -Be '76/76'
        $result.P | Should -Be '35/35'
        $result.B | Should -Be '9/11'
    }
}
