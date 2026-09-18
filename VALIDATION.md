# Validation — 0.3.0-alpha11

## Scope

`0.3.0-alpha11` is a version-normalization release derived from the accepted `r11.10.4-fix23` source state. Runtime/ObjectModel/Hosting/Provider/backend behavior and the frozen contract matrix are unchanged; release/version metadata is synchronized across public package surfaces.

## Acceptance status

```text
PASS:        101 / 101
FAIL:          0 / 101
UNVERIFIED:    0 / 101
STATE:       PASS
```

The second adversarial semantic pass remains clean. The complete supplemental static suite was rerun for this normalized release using the Library-provided Tree-sitter 0.25.1 / tree-sitter-pwsh 0.38.1 packages: 88 PowerShell files parsed with 0 failures/issues, and Clean Architecture, module layout, verb/API, architecture AST, backend routing, kubectl IPC protocol, Provider/ObjectModel and package reproducibility audits all passed.

The preparation container has Go 1.23.2 while the native host declares Go 1.26.0. A local `go test ./...` attempt therefore requested the Go 1.26 toolchain and could not download it because this environment has no network access. No Go semantic code changed from the accepted fix23 baseline; the only native-host change is the advertised `BuildVersion`, and the static kubectl protocol/version-coherence audit passed.

`docs/CONTRACT-VERIFICATION-MATRIX-V1.md` and `docs/PROVIDER-CONTRACT.md` are unchanged from the accepted fix23 baseline.

# Validation — r11.10.4-fix23

## Scope

fix23 changes documentation only. Production code, test code, frozen matrix rows/evidence lanes/severities, and provider/design contracts are byte-identical to fix22.

## Authoritative acceptance status

The complete frozen matrix remains accepted after the fix21 H7 correction:

```text
PASS:        101 / 101
FAIL:          0 / 101
UNVERIFIED:    0 / 101
STATE:       PASS
```

The second adversarial semantic pass remains clean across the highest-risk frozen rows and did not expand any invariant.

## Complete supplemental static rerun

The Library contains the exact development packages declared by this repository: `tree-sitter` 0.25.1 and `tree-sitter-pwsh` 0.38.1. They were materialized locally and used to rerun the complete `npm run test:static` suite against the fix23 source tree. No network dependency resolution was used.

Results:

- Clean Architecture boundary audit — PASS (21 Runtime C# files);
- PowerShell module-layout audit — PASS;
- Tree-sitter PowerShell syntax audit — PASS: 88 files, 0 failed, 0 issues, 0 `ERROR`/`MISSING` nodes;
- approved verb/public API audit — PASS: 249 functions, 104 root exports, 8 aliases;
- generic architecture AST audit — PASS for all 8 generic resource paths;
- capability-aware backend routing audit — PASS;
- kubectl IPC protocol audit — PASS (`859ffcd280d7…`);
- Provider/ObjectModel architecture audit — PASS;
- package reproducibility audit — PASS.

The earlier fix21 preparation note that tree-sitter-dependent audits had not been executed described the then-local dependency state before the Library packages were materialized. It is retained below as historical context and is not the current validation status.

`docs/CONTRACT-VERIFICATION-MATRIX-V1.md` and `docs/PROVIDER-CONTRACT.md` remain byte-identical to fix22.

# Validation — r11.10.4-fix22

## Scope

fix22 changes documentation only. Production code, test code, frozen matrix rows/evidence lanes/severities, and provider/design contracts are unchanged from fix21.

## Authoritative acceptance status

The complete frozen matrix was rerun after the fix21 H7 correction with the required executable lanes available:

```text
PASS:        101 / 101
FAIL:          0 / 101
UNVERIFIED:    0 / 101
STATE:       PASS
```

A second adversarial semantic pass then rechecked the highest-risk areas (`B1/B3`, `D7`, `F7/F8`, `H6-H10`, `I4-I8`, `K3/K9`, `L1-L9`) against the minimal invariants of frozen v1. No additional semantic discrepancy was found and no frozen requirement was expanded.

## Documentation reconciliation

The fix21 section below is retained as a historical preparation-environment record. Its statement that executable H7 acceptance was still pending describes the state before the full external rerun; it is no longer the current release status.

The frozen matrix remains exactly 101 cells. `docs/CONTRACT-VERIFICATION-MATRIX-V1.md` and `docs/PROVIDER-CONTRACT.md` are unchanged from fix21.

# Validation — r11.10.4-fix21

## Scope

fix21 is based on r11.10.4-fix20 and changes only Runtime payload identity validation, the H7 cluster-free fixture, and release documentation. The frozen v1 matrix remains exactly 101 cells.

## Targeted semantic validation

- version-neutral grouped GVR + payload from another API group is rejected before backend selection;
- group validation is independent of preferred-version resolution;
- resolved GVRs retain the existing exact `apiVersion` validation;
- H7 fixture covers `name`, `kind`, and `group` mismatch;
- the group regression is exercised through Create, Replace, and Apply;
- D7/F7/F8 interpretation and implementation are untouched.

## Validation in the preparation environment

Passed:

- Clean Architecture boundary audit;
- PowerShell module-layout audit;
- approved verb/public API audit;
- capability-aware backend-routing audit;
- kubectl IPC protocol audit;
- Provider/ObjectModel architecture audit;
- package reproducibility source audit;
- `git diff --check`.

Not executable in this environment:

- PowerShell/.NET F/P/B matrix lanes (`pwsh` and .NET SDK are absent);
- tree-sitter-dependent source audits (local npm dev dependencies are absent);
- native Go test lane (repository requires Go 1.26; environment provides Go 1.23.2).

At fix21 preparation time, the authoritative executable rerun was still pending in an environment with the declared PowerShell/.NET/Go toolchain; the preparation-environment source review alone did not close H7. The later complete rerun is recorded in the fix22 section above.

# Validation — r11.10.4-fix20

## Scope

fix20 is documentation-only and based on r11.10.4-fix19. It clarifies frozen-v1 interpretation after a manual-review false positive that broadened D7 into a discovery-freshness requirement already owned by F7/F8. No matrix row, evidence lane, severity, Runtime/ObjectModel/Hosting/Provider/backend/module code or test code changed.

## Validation

- frozen matrix row count remains 101;
- `git diff --check` passes;
- executable/source trees outside documentation/release notes are byte-identical to fix19;
- D2/D7 versus F1/F3/F7/F8 responsibility is now explicit in the contract;
- manual review is required to test the minimal invariant of each frozen row before considering additional policy as a contract failure.

The previously green fix19 executable matrix remains the executable evidence for the unchanged code.

# Validation — r11.10.4-fix19

## Scope

fix19 is based on r11.10.4-fix18 and targets only the second frozen-v1 manual-review failures B1, D7, I4 and I7. The 101-cell matrix is unchanged.

## Added/strengthened executable evidence

- Provider config-store mount preserves whitespace-only and leading/trailing-space kubeconfig filenames exactly.
- D7 uses production-like cached discovery and verifies fresh preferred GVR resolution for Apply, Create and Delete without changing locator identity.
- I4 exercises mixed Unknown/Unavailable/Unsupported permutations so unresolved Unknown cannot be hidden by a definite failure state.
- I7 verifies fail-fast behavior for wrong interface, missing constructor/member contract and repository-local assembly missing the expected type, while I6 still accepts ordinary optional load failures.

## Static/source validation executed here

This preparation environment has Node.js 22 but no PowerShell or .NET SDK. The following dependency-free gates were executed against the final source tree and passed:

- Clean Architecture audit — PASS (21 Runtime C# files)
- PowerShell module layout audit — PASS
- approved verb/public API audit — PASS (249 functions, 104 root exports, 8 aliases)
- capability-aware backend routing audit — PASS
- kubectl IPC protocol audit — PASS
- Provider/ObjectModel architecture audit — PASS
- package reproducibility audit — PASS

The routing audit now additionally requires Unknown to dominate Unavailable during unresolved failure aggregation and forbids swallowing MissingMethod/MissingField adapter contract failures. The Provider/ObjectModel audit requires fresh mutation-time preferred resolution and exact config-set path loading.

The tree-sitter-dependent architecture audit was not executable here because the local `tree-sitter` development dependency is absent.

## Required executable acceptance

```powershell
pwsh -NoProfile -File ./Tests/ContractMatrix.ps1 `
    -PowerShell74Path /opt/microsoft/powershell/7.4.20/pwsh
```

A green automated result must still be followed by the same manual semantic review of frozen A1→L9.

# Validation — r11.10.4-fix18

## Scope

fix18 is based on r11.10.4-fix17 and targets only the frozen-v1 manual failures B1, B3 and F7. The 101-cell matrix is unchanged.

## Added/strengthened executable evidence

The cluster-free ObjectModel fixture now covers:

- trailing-space kubeconfig paths preserved as distinct execution identity;
- one path containing U+001F vs two paths around that separator;
- one path containing `Path.PathSeparator` vs two ordered paths;
- order reversal and duplicate path entries;
- case-distinct and explicit whitespace Kubernetes context names;
- production-like cached discovery where ordinary topology remains stale and `refresh:true` reconciles CRD add/remove without ObjectModel directly invalidating backend cache.

PowerShell/Pester coverage additionally checks exact Runtime/config-set path preservation, ordered duplicates, explicit whitespace context persistence, lossless-KUBECONFIG export refusal, and process-backend fail-closed support evaluation.

## Static/source validation executed here

This preparation environment has Node.js 22 but no PowerShell or .NET SDK. The following dependency-free gates were executed against the final source tree and passed:

- Clean Architecture audit — PASS (21 Runtime C# files)
- PowerShell module layout audit — PASS
- approved verb/public API audit — PASS (249 functions, 104 root exports, 8 aliases)
- capability-aware backend routing audit — PASS
- kubectl IPC protocol audit — PASS
- Provider/ObjectModel architecture audit — PASS
- package reproducibility audit — PASS

The routing/source audit explicitly verifies canonical target identity use by ObjectModel, managed discovery and the Go session pool, rejects the former delimiter-based key forms, verifies process-backend KUBECONFIG fail-closed handling, and checks that Managed/Go discovery honor `refresh=true` at their owned cache boundary.

## Required executable acceptance

Run the unchanged frozen matrix in the user's toolchain:

```powershell
pwsh -NoProfile -File ./Tests/ContractMatrix.ps1 `
    -PowerShell74Path /opt/microsoft/powershell/7.4.20/pwsh
```

The expected target after fix18 is 101/101 only if the new B1/B3/F7 executable assertions and every existing S/F/P/B cell pass. This preparation environment does not claim those executable results.
