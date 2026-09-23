# Backend contract hardening after routing rework

Status: r7 source candidate after the third-ring architectural cleanup. The preceding r6-testfix2 cluster-free suite passed on the development host; r7 requires the same fixed local gate set before promotion.

This iteration is intentionally bounded. It hardens the correctness and architectural-contract issues found by the second routing audit without reopening the wider Provider migration or unrelated SRP cleanup.

## Scope

Implemented now:

1. PowerShell target/session state vs Runtime `KubeExecutionContext` boundary.
2. Normative backend support-state semantics and Managed target/resource/verb probing.
3. Go workload/debug evaluator/executor parity for deterministic support rules.
4. One public `IKubeBackend.ExecuteAsync` precondition: every backend self-enforces support before execution.
5. Representative Managed/Go Runtime error-taxonomy parity.
6. Managed discovery cache isolation by impersonation/security identity.
7. Type-safe specialized capability selection.
8. Removal of raw backend collections/instances from `KubeShell.Api`.
9. Diagnostics interface segregation.

Third-ring cleanup implemented in r7:

- decomposed the former `RuntimeAdapter.ps1` by reason to change: composition, errors, resources/watch, config/discovery/schema, workloads, diagnostics and streaming/copy/debug;
- separated raw external-process mechanics into `KubectlProcessTransport`; the semantic `KubectlProcessBackend` no longer owns raw CLI execution helpers, and `Invoke-Kubectl` consumes the transport directly;
- removed the unused `KubeOperationResult.BackendId` infrastructure-provenance field;
- invalidated cached semantic composition when Managed becomes available after an earlier selector was built, disposing the old long-lived Go host before recomposition;
- documented `CorrelationId` as best-effort observability metadata rather than a Kubernetes-operation semantic precondition.

Deferred deliberately after r7:

- final `Unknown` error representation;
- a wider product decision on whether every debug DTO detail is a KubeShell domain contract;
- the Provider migration itself.

`Optional/KubeShell.Provider` is unchanged in this change set.

## Provider-facing Runtime boundary

The future Provider is a design constraint for this work even though its implementation is out of scope.

The intended dependency direction is:

```text
KubeShell.Provider
      |
      v
Runtime semantic clients / ports
  IKubeResourceClient
  discovery/schema/diagnostic clients as needed
      |
      v
composition-owned routing
      |
      +--> Managed KubernetesClient
      +--> Go kubectl-host
      `--> process compatibility fallback
```

Provider code should not receive the backend array, select a concrete backend, or depend directly on `KubeBackendRouter`. The selector is routing infrastructure injected by a composition root into semantic Runtime clients. `IKubeResourceClient` now accepts `KubeExecutionContext` on CRUD calls so the same narrow port can later serve both PowerShell cmdlets and Provider operations without duplicating routing policy.

Core no longer exports `New-KubeRuntimeBackend`, `Get-KubeRuntimeBackendSelector`, or `Get-KubeRuntimeOperationClient` to sibling frontend modules. Semantic client factories remain the outward boundary.

## Correctness changes

### Execution context

PowerShell session/target selection is now named `Get-KubeSessionState`. The historical `Get-KubeExecutionContext` remains as a compatibility wrapper for that state, while `Get-KubeRuntimeExecutionContext` constructs the actual Runtime DTO.

Generic CRUD now carries `KubeExecutionContext` through `IKubeResourceClient`, matching watch/discovery/schema/workload/diagnostic/log/copy/debug paths.

### Support-state contract

The operative interpretation is:

- `Supported`: the backend can preserve the requested semantics and all deterministic prerequisites that can be established before execution have been proved, including local target/session resolution and relevant discovered resource/verb requirements;
- `Unsupported`: the request shape/options or discovered API surface are known to be incompatible with that backend;
- `Unavailable`: the backend mechanism or required local configuration is not usable;
- `Unknown`: support cannot be established safely; it is non-executable, but a later backend may still explicitly prove `Supported`.

`Supported` is not a promise that the subsequent Kubernetes request succeeds. Authorization changes, conflicts, server failures, cancellation and transport failures after execution begins remain execution failures and never trigger automatic another-backend replay.

Managed now resolves the target/resource and checks the required API verb before reporting `Supported` for generic operations. The default Managed backend no longer guesses ambient kubeconfig when Runtime supplied no explicit kubeconfig path.

### Go workload/debug parity

The Go support evaluator now includes the deterministic executor rules that can be checked before selection:

- scale requires base `get`; non-client-preview execution requires a discovered `scale` subresource advertising `patch`;
- rollout undo/restart/status validates supported workload kinds and required verbs;
- set-image validates the supported workload/pod-template kind surface and required verbs;
- debug resolves the target and limits semantic support to the core/v1 Pod/Node surface implemented by the host.

Data-dependent failures such as an absent named container remain execution/validation errors rather than capability-state rewrites.

### Execute precondition

Managed, Go and process backends all self-enforce their support contract in `ExecuteAsync`. The router still selects before execution and never catches an execution failure to try another backend. This makes direct backend calls safe with respect to semantic guards while preserving one-shot mutation behavior.

### Error taxonomy

The Managed HTTP mapper now aligns representative API-server statuses with the Runtime taxonomy used by the Go adapter:

| API status | Runtime kind |
| --- | --- |
| 400 | `InvalidResource` |
| 401 | `Authentication` |
| 403 | `Authorization` |
| 404 | `NotFound` |
| 405 | `Unsupported` |
| 409 | `Conflict` |
| 422 | `InvalidResource` |
| other HTTP failures, including 429/5xx | `Transport` |

Cancellation remains `Cancelled` in both semantic backends.

### Managed discovery cache identity

Managed discovery cache identity now includes the security-relevant impersonation user/uid/groups/extra values in addition to target identity, preventing discovery data obtained under one impersonated identity from being reused for another.

## Architectural hardening

### Typed capability selection

Specialized requests now inherit from `KubeCapabilityRequest<TBackend>`. `IKubeBackendSelector.SelectCapabilityAsync<TBackend>` accepts that typed request, so the compiler links the request to the semantic port. A schema request can no longer be passed as a log capability merely because one backend implements both interfaces.

### `KubeShell.Api`

`KubeShell.Api` no longer receives a backend collection or exposes a `Backend` instance in its session. Context-based sessions receive semantic Runtime clients from Core. Explicit server/credential sessions are also composed inside Core and return only Resource/Discovery/Operation clients plus Runtime execution context.

### Diagnostics ISP

The former `IKubeDiagnosticsBackend` is split into narrow ports:

- `IKubeAccessReviewBackend`;
- `IKubePodMetricsBackend`;
- `IKubeNodeMetricsBackend`;
- `IKubeDnsProbeBackend`.

A future backend can implement only the diagnostic capability it actually owns.

### Runtime policy names

Runtime workload field-manager defaults now use KubeShell-owned identities (`kubeshell-rollout`, `kubeshell-set-image`) rather than `kubectl-*` implementation names. This avoids baking an adapter identity into contracts later consumed by Provider.

## Bounded reflection result

The agreed exit invariants were checked after implementation:

1. **Support-state meaning is coherent across semantic backends** — PASS at source/contract level. Managed and Go both distinguish local/configuration/transport unavailability from known unsupported shapes and unknown discovery/authorization outcomes.
2. **A deterministic backend-local `Unsupported` branch is not hidden behind `Supported` for unchanged input** — PASS for the reviewed Managed generic and Go workload/debug surfaces. Runtime/data-dependent validation errors are intentionally separate.
3. **No routing after execution begins** — PASS. Selection and execution remain separate; clients invoke exactly one selected backend.
4. **Runtime execution context is propagated consistently** — PASS at the PowerShell/source boundary. Generic CRUD and specialized paths use the actual Runtime DTO.
5. **Representative API failures normalize to one Runtime error taxonomy** — PASS for the explicitly covered status classes above; conformance tests should be executed locally.
6. **Frontend/use-case code does not receive raw backend composition** — PASS for the current PowerShell/Optional API surface. Core owns the composition; Provider remains unchanged and is expected to consume semantic Runtime clients later.

A single second-order pass then searched for classes of defects that the strengthened architecture tests could still miss: stale session-state calls crossing the Runtime boundary, raw backend composition outside Core, direct backend execution bypasses, remaining fat diagnostics interface references, deterministic unsupported branches in Go workload/debug, and concrete backend coupling in Provider. No new High/Medium correctness class was found. The pass did find that three routing/composition helpers were still exported from Core; those exports were removed as part of the existing frontend-boundary finding rather than opening a new refactoring scope.

Per the agreed stop rule, broader style/SRP debt is not used to reopen this iteration.

## Third-ring Clean Architecture result

The cleanup preserves the dependency rule while reducing outer-layer responsibility mixing:

- `RuntimeComposition.ps1` is the only Core composition root for ambient semantic clients; use-case wrappers no longer share one 500+ line adapter file.
- raw external-process mechanics are isolated in `KubectlProcessTransport`; semantic support decisions remain in `KubectlProcessBackend`.
- Runtime results expose resources/warnings/diagnostics only. Backend provenance is intentionally absent from the semantic result contract.
- late optional-backend availability is a composition lifecycle event, handled by one reset path rather than by frontend modules.
- Provider remains unchanged and will later consume Runtime semantic clients/ports rather than either the PowerShell wrappers or concrete backend/transport objects.

The third ring intentionally does not redesign `KubeBackendRouter`, capability states, debug semantics or Provider. Those would reopen already-stabilized contracts rather than reduce the identified SRP/lifecycle debt.

## Static validation in this environment

The complete static suite passes:

```text
npm run test:static

Clean Architecture boundary audit passed (19 Runtime C# files).
PowerShell module layout audit passed for 4 split modules.
Checked 72 PowerShell files; 0 failed; 0 issue(s).
Verb/API audit passed: 238 functions use approved verbs; root exports 104 functions and 8 aliases with no duplicates or manifest drift.
Architecture boundary audit passed for 8 generic resource paths.
Capability-aware backend contract audit passed.
Kubectl IPC protocol audit passed (contract 859ffcd280d7…).
```

`git diff --check` also passes and `Optional/KubeShell.Provider` has zero diff.

This environment still cannot run the authoritative build/cluster-free runtime suite: `pwsh` and `dotnet` are absent and installed Go is 1.23.2 rather than the project Go 1.26+ line. Therefore this snapshot is a **source candidate** until the following local validation succeeds.

## Local cluster-free validation

No Kubernetes cluster is required for these gates.

From the repository root on the normal development host:

```powershell
# Toolchain sanity
$PSVersionTable.PSVersion
dotnet --info
go version

# Go kubectl-host: project requires Go 1.26+.
Push-Location ./native/kubeshell-kubectl/host
try {
    go test ./...
}
finally {
    Pop-Location
}

# Build Runtime and all semantic backend assemblies / bundled host.
./Runtime/KubeShell.Runtime/build.ps1
./Backends/KubeShell.KubectlProcess/build.ps1
./Backends/KubeShell.KubernetesClient/build.ps1
./Backends/KubeShell.Kubectl/build.ps1 -BuildHost

# Full cluster-free PowerShell/Pester suite. Do NOT add -Integration.
./Tests/Run.ps1 -RequirePester

# Optional independent source/static audit if Node dependencies are present.
npm run test:static
```

For this iteration Provider itself is deliberately not rebuilt as evidence of its migration: its source is unchanged. A normal full package may still compile/import the existing Provider as a regression gate, but any Provider conversion to the Runtime clients is a separate task after this candidate passes the cluster-free suite.

## Stop condition

If the local cluster-free suite exposes a compile/runtime regression, fix that concrete regression and rerun the same fixed gate set. Do not restart a broad architectural audit unless the failure reveals a new High/Medium correctness class violating one of the six invariants above.
