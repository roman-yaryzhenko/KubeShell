# r7 architecture cleanup

## Scope

This revision performs the deferred third-ring cleanup after r6-testfix2 passed the cluster-free suite. It deliberately preserves the routing/support/error contracts proven in r6 and keeps `Optional/KubeShell.Provider` source unchanged.

### Core SRP

The former `Modules/KubeShell.Core/Private/RuntimeAdapter.ps1` is removed. Its responsibilities are split into:

- `RuntimeComposition.ps1` — backend composition, lifecycle/reset and semantic client factories;
- `RuntimeErrors.ps1` — Runtime-to-PowerShell error/dry-run adaptation;
- `RuntimeResources.ps1` — generic CRUD/watch result adaptation;
- `RuntimeDiscovery.ps1` — config/discovery/schema use cases;
- `RuntimeWorkloads.ps1` — rollout/scale/image operations;
- `RuntimeDiagnostics.ps1` — access/metrics/DNS operations;
- `RuntimeStreaming.ps1` — logs/copy/debug operations.

No public PowerShell command surface changes.

### Process adapter SRP

`KubeShell.KubectlProcess` now has two responsibilities represented by two types:

- `KubectlProcessBackend` — `IKubeBackend` support policy, semantic operation-to-kubectl mapping and normalized semantic errors;
- `KubectlProcessTransport` — executable/process lifetime, stdin/stdout/stderr, context/namespace argument projection and KUBECONFIG environment projection.

The explicit `Invoke-Kubectl` escape hatch consumes `KubectlProcessTransport` directly; it no longer uses the semantic backend as a raw-process utility.

### Runtime result boundary

`KubeOperationResult.BackendId` is removed. No consumer used it, and concrete backend provenance is an infrastructure/telemetry concern. Semantic results continue to carry resources, warnings and diagnostics.

### Composition lifecycle

Core now has one `Reset-KubeRuntimeComposition` path. Module removal and late Managed-backend availability both use that path. The reset disposes the cached Go backend/host and clears semantic selector/client caches before recomposition, so Managed can assume first priority when it becomes available after initial composition.

### Correlation metadata

`KubeExecutionContext.CorrelationId` is documented as best-effort observability metadata. Managed and Go transports carry it; the external kubectl process may omit it without being classified as semantic weakening.

## Provider constraint

Provider source remains unchanged. The intended later direction remains Provider -> Runtime semantic clients/ports. Provider must not consume `RuntimeComposition.ps1`, raw backend arrays, `KubectlProcessTransport`, or concrete backend types.

## Validation

In this environment the complete static suite passes after the r7 changes:

```text
Clean Architecture boundary audit                  PASS
PowerShell module layout audit                      PASS (Core: 13 private units)
Tree-sitter PowerShell parse                        PASS / 78 files / 0 issues
Approved verb/public API audit                      PASS / 237 functions / 104 exports / 8 aliases
Generic architecture boundary audit                 PASS / 8 resource paths
Capability-aware backend contract audit             PASS
Kubectl IPC protocol audit                          PASS / 859ffcd280d7...
git diff --check                                    PASS
```

`pwsh`, `dotnet` and Go 1.26 are still unavailable in this execution environment. r7 therefore needs the same local cluster-free gate that already passed for r6-testfix2:

```powershell
./Runtime/KubeShell.Runtime/build.ps1
./Backends/KubeShell.KubectlProcess/build.ps1
./Backends/KubeShell.KubernetesClient/build.ps1
./Backends/KubeShell.Kubectl/build.ps1 -BuildHost
./Tests/Run.ps1 -RequirePester
```

No cluster is required.

## Stop rule

After that local gate is green, the third-ring cleanup is closed. Only a concrete compile/Pester/Go regression caused by this revision should be repaired. A new broad architectural audit is out of scope unless such a regression exposes a new High/Medium correctness class.
