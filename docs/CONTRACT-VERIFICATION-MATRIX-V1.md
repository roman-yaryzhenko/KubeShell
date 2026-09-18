# KubeShell r11 contract-verification matrix v1

Status: frozen acceptance matrix for the Provider/ObjectModel iteration.

A matrix row is `PASS` only when every evidence lane named by that row has actually executed. Source inspection is not a substitute for executable evidence. `UNVERIFIED` is therefore a valid release-review state and must not be silently promoted to `PASS`.

Evidence lanes:

- `S` — PowerShell-native frozen-contract source audit (`Tests/ContractStatic.ps1`). Supplemental Node/tree-sitter audits may run in development/CI but are not a local acceptance dependency.
- `F` — cluster-free .NET executable fixture.
- `P` — Pester/PowerShell behavior test.
- `B` — clean build/import/package lane.
- `I` — live Kubernetes integration; confidence-only/opt-in for r11.

Local frozen-matrix prerequisites are PowerShell, .NET SDK, Go and Pester. Node.js, npm and tree-sitter are deliberately **not** required by `Tests/ContractMatrix.ps1`; the extended JavaScript/tree-sitter audits remain supplemental development/CI evidence.

Severity:

- `BLOCKER` — wrong cluster/object identity or mutation, destructive replay, safety/WhatIf bypass, semantic identity collision, or inability to build/load the declared package.
- `MAJOR` — public semantic-contract violation, backend-dependent semantics, unnecessary RBAC privilege, incorrect navigation/capability/error behavior, or a dependency boundary that forces a future breaking change.

## Frozen-row interpretation discipline

This matrix is frozen at the level of **contract meaning as well as row count**. Manual review may discover an implementation counterexample, but it must not silently strengthen a row beyond its minimal stated invariant. Before recording a manual `FAIL`, the reviewer must check whether the suspected requirement is already owned by another row. A stricter implementation policy may be valuable, but it is not retroactively part of a frozen row unless the matrix is explicitly revised in a later version.

In particular:

- D2/D7 own version-neutral resource identity and preferred-GVR resolution semantics.
- F1/F3/F7/F8 own cacheability, explicit refresh and discovery-cache ownership/freshness semantics.
- Therefore D7 does **not** require a server-fresh discovery round-trip before every GET/LIST or other resource I/O. It requires that preferred version is not baked into the locator/stable ID and that, when the discovery view changes between calls, subsequent resolution can execute through the newly preferred GVR.
- Ordinary reads/navigation may use the current cached discovery snapshot. Explicit topology `-Refresh` must reconcile discovery according to F7, while F8 keeps backend-cache mechanics behind the discovery contract. An implementation may choose a stronger freshness policy for mutations; that is an implementation guarantee, not an extra D7 acceptance requirement.

This interpretation rule exists to prevent semantic scope creep during adversarial/manual review while preserving the ability to find real counterexamples to the frozen contract.

## A. Dependency graph

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| A1 | Provider may use ObjectModel/Runtime/Hosting/PowerShell; concrete backends/router/process/kubectl APIs are forbidden. | S | MAJOR |
| A2 | ObjectModel depends on Runtime only; no PowerShell/Hosting/concrete backend dependency. | S | MAJOR |
| A3 | Runtime has no PowerShell or concrete backend references and builds independently. | S+B | MAJOR |
| A4 | Hosting is composition/lifecycle only and exposes semantic clients, not router/backend collections as application API. | S+F | MAJOR |

## B. Semantic identity and locator state-space

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| B1 | Target identity is context + ordered kubeconfig set; Source/Profile/ConfigSet/DefaultNamespace do not change it. | F | BLOCKER |
| B2 | One object reached through target/namespace/collection/profile/direct-context roots has one stable ID. | F | MAJOR |
| B3 | Different cluster/context/kubeconfig execution identities never collide. | F | BLOCKER |
| B4 | Collection accepts Cluster/Explicit/All; Item accepts Cluster/Explicit; Default and Item-All are rejected. | F | BLOCKER |
| B5 | Same name across namespaces and core/grouped same-resource names have distinct identity. | F | BLOCKER |
| B6 | Node metadata is an owned immutable snapshot. | F | MAJOR |

## C. Mount truth table

| ID | Input | Required result | Evidence | Fail |
|---|---|---|---|---|
| C1 | no Namespace/Resource/All | TargetRoot | F+P | MAJOR |
| C2 | Namespace only | NamespaceLocator | F+P | MAJOR |
| C3 | Namespace + namespaced Resource | Explicit collection | F+P | MAJOR |
| C4 | namespaced Resource + AllNamespaces | All collection | F+P | MAJOR |
| C5 | namespaced Resource without scope | reject | F+P | MAJOR |
| C6 | cluster Resource without namespace | Cluster collection | F+P | MAJOR |
| C7 | cluster Resource + Namespace | reject | F+P | MAJOR |
| C8 | cluster Resource + AllNamespaces | reject | F+P | MAJOR |
| C9 | AllNamespaces without Resource | reject | F+P | MAJOR |
| C10 | Namespace + AllNamespaces | reject | F+P | MAJOR |
| C11 | profile/configset current-context mount | context is frozen; later ambient current-context change cannot retarget drive | F+P | BLOCKER |

## D. Discovery

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| D1 | Built-ins and CRDs appear without Provider code changes. | F | MAJOR |
| D2 | Version-neutral canonical grouped resource resolves across all served versions and selects preferred GVR when present; a resource present only in a non-preferred served version remains resolvable. | F | MAJOR |
| D3 | Canonical core GroupResource cannot be reinterpreted as an identically named grouped resource. | F | BLOCKER |
| D4 | canonical resource.group, plural, singular, Kind and shortName aliases canonicalize when unique. | F | MAJOR |
| D5 | Alias matching multiple GroupResources is an explicit ambiguity error. | F | BLOCKER |
| D6 | Descriptor scope and locator scope mismatch is rejected before resource I/O. | F | BLOCKER |
| D7 | Preferred API version may change between calls without changing locator/ID; execution uses the new preferred GVR. | F | MAJOR |
| D8 | Partial aggregated discovery retains useful successful groups. | F | MAJOR |
| D9 | Managed and native discovery apply the same KubeShell token/no-match/ambiguity/orphan-subresource semantics to the same discovery corpus. | F+B | MAJOR |

## E. Navigation and RBAC locality

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| E1 | Creating TargetRoot performs no resource list. | F | MAJOR |
| E2 | Enumerating Namespaces performs namespace list. | F | MAJOR |
| E3 | Resolving a named namespace directly does not require list namespaces. | F | MAJOR |
| E4 | Enumerating a Namespace discovers resource kinds without listing every resource collection. | F | MAJOR |
| E5 | Enumerating a namespaced collection performs namespace-local list. | F | MAJOR |
| E6 | Enumerating AllNamespaces root performs list-all then bucket grouping. | F | MAJOR |
| E7 | Resolving a named AllNamespaces bucket directly performs no list-all. | F | MAJOR |
| E8 | Enumerating a known bucket performs namespace-local list. | F | MAJOR |
| E9 | Resolving/getting a named item uses point GET, without collection list. | F | MAJOR |
| E10 | Test-Path concrete item uses point GET; NotFound is false and other errors survive. | F+P | MAJOR |
| E11 | Delete concrete item has no read/list preflight. | F+P | MAJOR |

## F. Cache, refresh and live data

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| F1 | Navigation topology may cache; resource lists/items stay live by default. | F | MAJOR |
| F2 | Cache is isolated by TargetKey. | F | BLOCKER |
| F3 | Warm topology reuses navigation cache. | F | MAJOR |
| F4 | Refresh rematerializes stale root topology. | F+P | MAJOR |
| F5 | Deep Refresh reaches the final topology edge required to resolve the requested child. | F+P | MAJOR |
| F6 | Refresh also rematerializes children of the resolved target container. | F+P | MAJOR |
| F7 | Added/removed CRD collection is reconciled after topology refresh. | F | MAJOR |
| F8 | ObjectModel refresh does not implicitly reset Runtime/backend discovery cache. | F | MAJOR |

## G. Frontend-neutral capabilities

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| G1 | Container/leaf capabilities correspond to operations actually executable by ObjectModel; Edit/Apply requires patch support, not update-only support. | F | MAJOR |
| G2 | Explicit collection with create verb advertises Create. | F | MAJOR |
| G3 | AllNamespaces collection root does not advertise Create. | F | MAJOR |
| G4 | Explicit namespace bucket with create verb advertises Create. | F | MAJOR |
| G5 | Future frontend can consume ObjectModel contracts without PowerShell types. | S | MAJOR |
| G6 | ObjectModel cancellation reaches semantic Runtime boundary. | F | MAJOR |

## H. Mutations

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| H1 | New-Item is atomic Create; no Exists+Apply. | F+P | BLOCKER |
| H2 | New-Item -Force maps to explicit frontend Apply/upsert policy. | P | MAJOR |
| H3 | Set-Item maps to Apply. | F+P | MAJOR |
| H4 | Remove-Item maps to Delete. | F+P | MAJOR |
| H5 | WhatIf prevents each mutation from crossing Runtime mutation boundary. | P | BLOCKER |
| H6 | Selected mutation execution failure is never replayed on a fallback backend. | F | BLOCKER |
| H7 | Payload identity name/group/kind mismatch is rejected before backend selection. | F | BLOCKER |
| H8 | Payload namespace mismatch with explicit locator scope is rejected. | F | BLOCKER |
| H9 | Namespace metadata on cluster-scoped payload is rejected. | F | BLOCKER |
| H10 | Invalid/incomplete optimistic-concurrency requirements fail closed. | F | BLOCKER |
| H11 | Node deletion policy requires Force and permits the explicit Force path. | P | BLOCKER |
| H12 | Runtime warnings/diagnostics survive success and failure through ObjectModel/Provider. | F+P | MAJOR |

## I. Backend routing and composition

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| I1 | Supported/Unsupported/Unavailable/Unknown remain distinct. | F | MAJOR |
| I2 | Managed -> Go -> Process preference selects first Supported backend. | F | MAJOR |
| I3 | Unsupported/Unavailable candidates allow a later Supported backend. | F | MAJOR |
| I4 | Unknown is non-executable, may be bypassed by later Supported, and final Unknown becomes Indeterminate. | F | MAJOR |
| I5 | Execution failure after selection is never replayed. | F | BLOCKER |
| I6 | Missing/bad-image/missing-dependency/type-load optional adapter failures allow later backend composition. | F | MAJOR |
| I7 | Configured adapter with wrong semantic interface/contract fails fast. | F | MAJOR |
| I8 | Failed optional adapter load detaches temporary assembly resolver/handler. | F | MAJOR |
| I9 | Host/drive lifetime disposes owned adapters once without killing an unrelated drive. | F | MAJOR |

## J. Errors and cancellation

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| J1 | Each KubeErrorKind remains backend-neutral. | F | MAJOR |
| J2 | OperationCanceledException from backend/router becomes KubeErrorKind.Cancelled at semantic boundary. | F | MAJOR |
| J3 | Provider operations expose stable KubeShell.Runtime.<Kind> ErrorId. | P | MAJOR |
| J4 | Test-Path/ItemExists maps NotFound to false. | P | MAJOR |
| J5 | ItemExists/IsItemContainer preserve non-NotFound Runtime failures. | P | MAJOR |
| J6 | Authentication/Authorization/Conflict/Unavailable map to correct PowerShell ErrorCategory. | P | MAJOR |
| J7 | Transport-specific status does not become Runtime semantic taxonomy. | F | MAJOR |

## K. Provider semantics

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| K1 | Dynamic Namespace/Resource/AllNamespaces parameters are exposed on the intended provider surface. | P | MAJOR |
| K2 | PowerShell path is presentation/navigation only; semantic locator is identity. | S+F | BLOCKER |
| K3 | Traversal is always relative to drive RootLocator. | F+P | MAJOR |
| K4 | Target/namespace/cluster collection/explicit collection/all collection roots work. | F+P | MAJOR |
| K5 | Leaf-root mounts remain unsupported in r11. | F+P | MAJOR |
| K6 | Recursive provider traversal is explicitly rejected. | P | MAJOR |
| K7 | PSCredential is explicitly rejected rather than ignored. | P | MAJOR |
| K8 | Provider contains no direct process/kubectl/nested-runspace domain execution. | S | MAJOR |
| K9 | Presentation-only fields never leak into Kubernetes wire JSON. | P | BLOCKER |

## L. Build/package compatibility

| ID | Contract | Evidence | Fail |
|---|---|---|---|
| L1 | Clean checkout builds every C# project used by package. | B | BLOCKER |
| L2 | PowerShell 7.4/.NET 8 builds Provider and imports packaged module. | B | BLOCKER |
| L3 | PowerShell 7.6/.NET 10 builds Provider and imports packaged module. | B | BLOCKER |
| L4 | Both lanes satisfy the same declared PowerShell compatibility contract. | B | BLOCKER |
| L5 | Provider SDK artifact uses portable PowerShell reference contract and does not bind to build-host SMA. | S+B | BLOCKER |
| L6 | Dirty checkout/stale bin+obj cannot contaminate package; only outputs freshly produced by this invocation are staged. | S+B | BLOCKER |
| L7 | Every manifest-referenced packaged DLL exists and loads. | B | BLOCKER |
| L8 | Full package builds/passes native host tests with required Go toolchain. | B | BLOCKER |
| L9 | Compile failure preserves complete compiler diagnostics rather than only an exit code. | P+B | MAJOR |

Total frozen checks/combinations: **101**. Live Kubernetes integration remains a separate optional confidence lane and cannot turn an unexecuted S/F/P/B requirement into PASS.

## Automated evidence ledger

`Tests/ContractMatrix.ps1` treats this table as the frozen source of truth. The cluster-free .NET
fixture emits `MATRIX_IDS:F=...`; the Provider behavior fixture emits `MATRIX_IDS:P=...`; the
PowerShell-native source audit returns its exact S IDs; package/import checks add B IDs only after
the corresponding action succeeds. `Tests/ContractEvidence.ps1` parses all 101 rows above and
refuses to convert a missing required lane into PASS. Without an explicit PowerShell 7.4 runner,
only L2 and L4 may remain `UNVERIFIED`; with one supplied, a successful strict run is 101/101.
