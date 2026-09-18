# Discovery-driven Provider/ObjectModel iteration (r11.2)

## Baseline

The implementation starts from `KubeShell-0.3.0-alpha10.9-ipc-r10-primitives-source.zip`. r10 already supplied a backend-neutral Runtime, typed resource CRUD including atomic Create/Replace, explicit namespace scope with All valid only for collection queries, discovery descriptors, semantic error taxonomy, target resolution and the Managed -> Go -> Process routing invariant. The old Provider was a separate implementation: one C# provider file contained a fixed resource catalog, topology/path parsing, configuration loading and direct kubectl process execution.

## Resulting dependency graph

```text
PowerShell Core ------------------------------┐
                                              │
Provider -> KubeShell.ObjectModel -> Runtime  │
   │                              ^            │
   └----------> KubeShell.Hosting |            │
                  | constructs/wires           │
                  +-> Managed -----------------+
                  +-> Go host -----------------+
                  +-> Process -----------------+

future TUI -> KubeShell.ObjectModel -> Runtime
```

Runtime has no Hosting/ObjectModel/Provider dependency. ObjectModel has only a Runtime project reference. Hosting is an outer composition root and may know concrete optional adapter names/paths; it exposes semantic Runtime clients rather than the router/backend collection. Provider uses Hosting only to bootstrap its drive-owned semantic clients, then performs navigation/mutations through ObjectModel.

## Implemented slices

1. **Rich Runtime resource execution port.** `IKubeResourceExecutionClient` and `KubeExecutionResult<T>` preserve warnings/diagnostics. The narrow `KubeResourceClient` unwraps the shared rich execution implementation while retaining lightweight Exists/TryGet/ListNames convenience methods.
2. **Frontend-neutral ObjectModel fundamentals.** Immutable semantic locators/nodes, stable IDs, async-first/cancellable navigation service, neutral capabilities/metadata and basic future operation descriptors.
3. **Discovery-driven topology.** Preferred discovery creates namespace/cluster resource collections; canonical identity is version-neutral `GroupResource`; aliases are canonicalized or rejected as ambiguous; CRDs need no Provider code change; AllNamespaces groups live resources into namespace buckets.
4. **Cache, refresh and arbitrary roots.** Semantic locator keys drive topology caching; resource lists remain live; refresh invalidates ObjectModel topology only; mounts can start at target, namespace, namespaced collection, all-namespaces collection or cluster collection.
5. **Shared Hosting/composition.** `KubeShell.Hosting` owns ordered backend construction, router creation and adapter lifetime. Core now owns one Hosting instance rather than reproducing backend order/router construction. Managed local dependency resolution is contained in Hosting/outer loading code.
6. **Provider migration.** The Provider no longer hardcodes Pods/Deployments/Services, invokes kubectl/process APIs, owns backend selection, or encodes Kubernetes topology in a giant path parser. Paths traverse ObjectModel one segment at a time relative to a drive RootLocator.
7. **PowerShell semantics.** Dynamic New-PSDrive Namespace/Resource/AllNamespaces parameters, `Get-ChildItem -Refresh`, explicit rejection of recurse, Create/Apply/Delete CRUD projection, ShouldProcess, Node deletion protection, rich warnings/diagnostics and Runtime error taxonomy mapping.

## Key types

Runtime: `GroupResource`, `KubeExecutionResult<T>`, `KubeExecutionResult`, `IKubeResourceExecutionClient`, `KubeResourceExecutionClient`, async members on `IKubeDiscoveryClient`.

ObjectModel: `KubeNodeLocator` hierarchy, `KubeNavigationNode`, `KubeNavigationCapabilities`, `KubeMountRequest`, `KubeTargetIdentity`, `IKubeNavigationService`, `KubeNavigationService`, and the initial `ObjectOperation*` descriptors.

Hosting: `KubeShellHostOptions`, `KubeShellHost`.

Provider: `KubeProviderDriveInfo`, `KubeNewDriveParameters`, `KubeRefreshParameters`, thin `KubeProviderItem`/`KubeProviderContainer` projections.

## Boundary changes

- Backend collection/router construction moved from PowerShell Core composition into `KubeShell.Hosting`.
- Provider domain/navigation logic moved into `KubeShell.ObjectModel`.
- Runtime gained a richer resource result port without replacing every Runtime API with result envelopes.
- Runtime discovery gained async facade methods for ObjectModel/TUI cancellation.
- Provider configuration file loading and default kubeconfig path resolution remain outer-adapter concerns; semantic profile/configset resolution still uses Runtime `KubeTargetResolver`.
- Preferred API version does not participate in long-lived navigation identity.

## Deferred/non-goals

No TUI, watch UI, log/exec/debug/port-forward UI, editor UI, full generic operation catalog, process-wide shared host, leaf-root PSDrive, exact-version mount, flattened all-namespaces view, custom navigation views, persistent cache infrastructure, or automatic recursive traversal was added. Provider-level `Edit-Item` was not invented; future edit/test/preview semantics remain separate from PowerShell WhatIf.

## Validation

The source includes `Tests/ProviderObjectModelAudit.mjs` for dependency/forbidden-coupling checks and a cluster-free `.NET` executable fixture at `Tests/Fixtures/KubeShell.Tests.ObjectModelFixture`. The latter exercises dynamic/CRD topology, alias ambiguity, scope validation, arbitrary roots, AllNamespaces collisions/buckets, cache/refresh, live lists, stable IDs, rich CRUD projection and cancellation.

Validation performed in the delivery environment:

- `npm run test:static` — **PASS** end-to-end using the library-provided `tree-sitter-0.25.1` and `tree-sitter-pwsh-0.38.1` prebuilt packages. This includes:
  - `CleanArchitectureAudit.mjs` — **PASS**;
  - `ModuleLayoutAudit.mjs` — **PASS**;
  - `SyntaxTree.mjs` — **PASS**, 82 PowerShell files parsed with 0 failures/issues;
  - `VerbAudit.mjs` — **PASS**, 237 functions use approved verbs and exports show no duplicates/manifest drift;
  - `ArchitectureAudit.mjs` — **PASS**, all 8 generic resource paths preserve the expected Runtime boundary;
  - `BackendRoutingAudit.mjs` — **PASS**;
  - `KubectlProtocolAudit.mjs` — **PASS**;
  - `ProviderObjectModelAudit.mjs` — **PASS**.
- `git diff --check` — **PASS**.
- The generated r10 -> r11 unified diff was applied with `git apply --check` and then applied to a clean archive of baseline commit `9c95d05`; the resulting 219-file source tree is byte-for-byte identical to the delivery working tree when `.git` and test-only `node_modules` are excluded — **PASS**.
- PowerShell/Pester and C# build/ObjectModel fixture — **NOT RUN** because the execution environment has no `pwsh`, `dotnet`, `csc`, `mcs` or `msbuild`. The library's prebuilt KubeShell DLLs are r10 binaries and therefore are not used as evidence for compilation of the modified r11 sources.
- Go tests — **NOT ESTABLISHED GREEN**: the execution environment has Go 1.23.2 while the current native source requests Go 1.26; automatic toolchain acquisition is unavailable in the isolated environment.

The PASS results establish source structure, dependency-direction, syntax, routing and reproducible-diff invariants. They do not substitute for compiling the changed C# projects or running the PowerShell/Pester suite. On the target development machine, the release gate remains the normal `Tests/Run.ps1 -RequirePester`, the ObjectModel fixture, and the regular package/build path with the required .NET and Go toolchains.

### Development-host compatibility hardening

- r11.1 makes the PowerShell-hosted Provider compiler tolerate only Roslyn `CS1701`/`CS1702` framework-unification warnings when PowerShell 7.6 (.NET 10) loads the net8.0 semantic assemblies. Production projects remain net8.0.
- r11.2 marks the cluster-free ObjectModel executable fixture with `RollForward=Major`. This permits a development machine that has a newer .NET runtime, but no `Microsoft.NETCore.App 8.x`, to execute the net8.0 fixture on that newer runtime. The policy is local to the test executable and does not change the target framework or roll-forward policy of production assemblies.
- `Tests/Run.ps1` now captures and includes `dotnet run` output when the ObjectModel fixture fails, rather than reporting only the process exit code.

## Delivery artifacts

The delivery is accompanied by:

- a complete r11 source archive;
- a unified Git diff relative to the exact r10 baseline commit/source;
- SHA-256 files for both artifacts.
