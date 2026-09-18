# Changelog — 0.3.0-alpha11

- Normalized public/product versioning from the internal `r11.10.4-fix23` lineage to `0.3.0-alpha11`.
- Updated PowerShell prerelease metadata, npm/package metadata, managed serialization/kubectl assemblies, native host build version, package builder default and contract-matrix package default to the same product version.
- Distribution naming is now `KubeShell-0.3.0-alpha11.*`; `r11...-fixN` remains historical provenance only.
- No Runtime/ObjectModel/Hosting/Provider/backend semantic behavior or frozen contract criterion changed.
- Frozen v1 matrix remains 101/101 PASS; the full supplemental static suite remains green.

# Changelog — r11.10.4-fix23

- Documentation-only validation reconciliation; production/test code remains unchanged from fix22.
- Reran the complete supplemental `npm run test:static` suite with the Library-provided `tree-sitter` 0.25.1 and `tree-sitter-pwsh` 0.38.1 packages.
- Tree-sitter parsed 88 PowerShell files with 0 failures/issues; generic architecture, routing, IPC protocol, Provider/ObjectModel and package reproducibility audits all passed.
- Frozen v1 matrix remains 101/101 PASS and frozen contract documents are unchanged.

# Changelog — r11.10.4-fix22

- Documentation-only reconciliation after the accepted fix21 verification.
- Recorded the complete frozen matrix result as `101/101 PASS` with zero FAIL/UNVERIFIED cells.
- Recorded the second adversarial semantic pass with no additional frozen-contract discrepancies.
- Reworded fix21 preparation-environment status so historical pending-execution text cannot be read as the current release state.
- No production/test code or frozen contract changed from fix21.

# Changelog — r11.10.4-fix21

- Closed frozen H7: version-neutral GVR payload validation now rejects API-group mismatch before backend selection.
- Preserved the existing distinction between always-known group identity and discovery-resolved concrete API version.
- Strengthened H7 F-lane evidence to cover name, kind and group mismatch, including Create/Replace/Apply version-neutral group cases.
- Frozen v1 matrix remains unchanged at 101 cells.

# Changelog — r11.10.4-fix20

- Clarified the frozen v1 contract interpretation boundary between D2/D7 preferred-GVR semantics and F1/F3/F7/F8 discovery freshness/cache ownership.
- Added an explicit manual-review discipline: frozen rows are evaluated by their minimal stated invariant and cannot be silently strengthened during adversarial review.
- Documented that ordinary reads may use the current discovery snapshot, explicit topology refresh requires fresh discovery, and mutation-time fresh preferred discovery is a stronger implementation policy rather than an added D7 acceptance requirement.
- No Runtime/ObjectModel/Hosting/Provider/backend/module/test code changed from fix19; the frozen matrix remains 101 cells.

# Changelog — r11.10.4-fix19

- Closed the remaining B1 frontend-boundary leak: Provider config-set JSON preserves every non-empty kubeconfig path exactly, including whitespace-only and leading/trailing-space filenames.
- Closed D7 by forcing fresh preferred-resource discovery at ObjectModel mutation time while keeping version-neutral locators/stable IDs unchanged.
- Closed I4 by making unresolved `Unknown` dominate definite `Unavailable`/`Unsupported` failure aggregation when no backend is `Supported`.
- Closed I7 by treating resolved adapter ABI/constructor/member/interface mismatches as fail-fast contract errors; only ordinary optional load failures may fall through.
- Added provider, cached-discovery, routing permutation, and Hosting contract-mismatch regressions.
- Frozen v1 matrix remains unchanged.

# Changelog — r11.10.4-fix18

- Closed manual frozen-matrix B1/B3 identity failures by preserving exact ordered kubeconfig paths and exact context identity.
- Added canonical length-prefixed `KubeTargetIdentityEncoding`; ObjectModel target keys, managed discovery cache identity and Go session pooling now consume that encoding instead of delimiter-flattened path lists.
- Removed config-set path deduplication so ordered execution identity survives the PowerShell configuration boundary.
- Made kubectl-process and explicit KUBECONFIG export fail closed when a path contains the platform path-list separator and cannot be represented losslessly.
- Closed F7 by propagating semantic `refresh=true` through ObjectModel topology/discovery resolution while keeping backend cache ownership inside each backend.
- Added production-like cached-discovery CRD add/remove evidence and adversarial B1/B3 fixtures for whitespace, separator, order, duplicate and case-distinct identities.
- Frozen v1 matrix remains unchanged.

# Changelog — r11.10.4-fix17

- Fixed the frozen evidence ledger's 101/101 happy path under StrictMode by replacing implicit `$unverified.Id` member enumeration with explicit ID projection.
- Added dedicated ledger regression tests for complete 101/101 PASS and the supported 99/101 partial branch without PowerShell 7.4.
- Added the ledger regression suite to the normal Pester run.
- Production Runtime/ObjectModel/Hosting/Provider/backend/module code is byte-for-byte unchanged from fix16.

# Changelog — r11.10.4-fix16

- Corrected the Provider fixture GET response model used by K9 round-trip evidence.
- Point GET request identities are GVR-addressed and may omit presentation `Kind`; synthesized fixture responses now recover Kind from the matching discovery descriptor, mirroring production response parsing.
- Strengthened K9 to verify `Name`, `Namespace`, `Kind`, `ApiVersion` and `RawJson` coherence before `Get-Item` output is passed back through `Set-Item`.
- Added explicit evidence that presentation-object round-trip maps to Apply and that presentation-only fields remain outside wire JSON.
- Production Runtime/ObjectModel/Hosting/Provider/backend/module code is byte-for-byte unchanged from fix15.
