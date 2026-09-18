# Backend routing architectural audit

> Historical first-pass routing audit. The routing-topology findings remain useful, but the current backend-contract state and bounded follow-up are documented in `BACKEND-CONTRACT-HARDENING.md`.

Status: source-level routing rework based on `KubeShell-0.3.0-alpha10.9-ipc-r5-source.zip`.

## Scope and baseline

The baseline already had three backend implementations, but they did not participate in one coherent semantic composition:

- `KubeShell.KubernetesClient` used the official .NET KubernetesClient, but normal Core composition did not include it.
- `KubeShell.Kubectl` used the long-lived `kubeshell-kubectl-host` and was preferred by Core when present.
- `KubeShell.KubectlProcess` was the external-process compatibility fallback.
- several specialized Runtime clients selected the first backend implementing their semantic interface and therefore bypassed operation/capability support evaluation.
- `Optional/KubeShell.Api` owned a separate managed-backend loader and created an isolated managed execution path for kubectl-context sessions.

`Optional/KubeShell.Provider` is intentionally outside this change set and was not modified.

## Architectural leaks and inconsistencies found

### 1. Specialized clients used interface presence as routing policy

Discovery, config, schema, watch, logs, copy, debug and diagnostics each carried local selection logic. The important failure mode was equivalent to “first backend implementing `IFooBackend` wins”. Interface presence says nothing about request-specific semantic support, availability, negotiated host features, preview mode or execution context.

### 2. Managed KubernetesClient was not in the common composition root

The official .NET backend was loaded by `Optional/KubeShell.Api`, while ordinary Core routing used Go host followed by the process backend. This made “managed is primary” impossible without entering a different frontend path.

### 3. Managed support evaluation was wider than its executor

`KubernetesClientBackend.EvaluateAsync()` could reach `Supported` for Runtime operation types outside the executor switch. This is especially dangerous once Managed moves to the first position: workloads/rollouts could be selected by routing and then fail only during execution.

### 4. External process fallback could silently lose execution-context semantics

The process backend mapped only a subset of execution-context features. In particular, field validation, a requested User-Agent and impersonation extra fields were not preserved by its semantic path. Those combinations now fail capability evaluation instead of reaching a weaker command invocation.

### 5. Optional API duplicated backend loading/composition policy

The optional API module contained its own `AssemblyLoadContext` resolver and managed assembly loader. Kubectl-context sessions consequently bypassed the same backend set used by the normal frontend.

### 6. Failure-after-selection needed an explicit one-shot rule

The previous generic client evaluated all backends and then executed a supported one. It did not currently replay on execution failure, but the distinction between capability fallback and execution retry was implicit. With a more capable router this distinction needs to be structural so a future catch/retry cannot duplicate a mutation.

## Implemented design

### Shared Runtime router

`KubeBackendRouter` is now the single ordered policy mechanism for generic operations and specialized semantic capabilities. Runtime owns only backend-neutral contracts:

- `KubeCapabilityRequest` records carry Runtime DTOs;
- `IKubeCapabilityEvaluator` reports `Supported`, `Unsupported`, `Unavailable` or `Unknown` for specialized requests;
- `SelectOperationAsync()` and `SelectCapabilityAsync<TBackend>()` walk the ordered backend set;
- `Unknown` is fail-safe and is never executable; routing may continue to a later backend that explicitly reports `Supported`;
- `Unsupported` and `Unavailable` may continue to a later backend;
- selection ends before execution starts.

`KubeOperationClient.ExecuteAsync()` selects exactly one backend and invokes it exactly once. It does not catch a selected backend failure and does not re-route after execution has started.

### Common composition order

Core now builds one ordered semantic backend set:

1. `KubeShell.KubernetesClient` when its optional assembly is installed/loaded;
2. `KubeShell.Kubectl` when the bundled Go-host adapter is available;
3. `KubeShell.KubectlProcess` when external `kubectl` is available.

The managed assembly remains optional at source-import time. Absence or optional load failure leaves the common composition valid, so Go becomes the first semantic backend. Absence of both semantic adapters still permits the process backend for operations its evaluator explicitly supports.

Release packaging now builds the primary managed backend by default. `-SkipManagedBackendBuild` exists for source-only packaging; the old `-BuildManagedBackend` switch remains accepted for compatibility.

### Optional API composition

The managed assembly resolver/loader moved to the Core composition root. `Optional/KubeShell.Api` no longer names concrete backend types.

Kubectl-context API sessions use `Get-KubeRuntimeBackends` and the common `KubeOperationClient`/`KubeDiscoveryClient`. Explicit-server sessions intentionally remain an isolated one-backend target because their credentials and TLS configuration are session-owned rather than part of the ambient KubeShell target; even there, calls pass through Runtime clients and the same one-shot routing semantics.

### Managed backend support surface

Managed is primary for operations naturally represented by the official KubernetesClient generated API while preserving Runtime semantics:

- get/list;
- create;
- replace, including `RequireUnchanged` resourceVersion handling;
- merge/json/strategic patch where accepted by the API server;
- server-side apply, including field manager and force-conflicts;
- server dry-run;
- field validation;
- Runtime request headers, timeout and impersonation headers;
- Kubernetes discovery.

Managed deliberately reports `Unsupported` for:

- client-side apply;
- client preview;
- generic subresources in the current adapter;
- patch/delete optimistic-concurrency modes not implemented by the adapter;
- forced replace semantics;
- watch and workload/rollout operation types handled by other semantic contracts;
- specialized schema/log/copy/debug/diagnostics/config capabilities not implemented by the managed adapter.

The executor and evaluator now have the same generic operation whitelist, so Managed cannot claim support for an operation the executor does not dispatch.

### Go host fallback surface

The Go backend remains a first-class semantic backend and evaluates both generic operations and specialized capability requests. It remains the preferred implementation where upstream Kubernetes/kubectl machinery supplies material semantic value:

- client-side apply and client preview;
- watch;
- schema/explain/OpenAPI semantics;
- client-go-resolved config view;
- logs;
- copy;
- debug;
- diagnostics;
- rollout/workload operations;
- kubectl/client-go-specific discovery or subresource behavior when Managed declines the operation.

Capability evaluation checks target prerequisites, host availability and negotiated protocol feature bits. Watch reuses the stricter generic operation evaluator so discovery verbs and operation options are evaluated consistently.

### Process compatibility fallback

The process backend remains last. It is eligible only for the generic CRUD/apply surface it explicitly maps and only when its evaluator can preserve the requested Runtime semantics. It fails closed for unsupported concurrency, generic subresources, non-default field validation, requested User-Agent and impersonation extra fields.

`Invoke-Kubectl` remains the explicit raw escape hatch and is outside semantic routing.

## Effective routing table

| Semantic operation group | Managed KubernetesClient | Go kubectl-host | External kubectl process |
| --- | --- | --- | --- |
| Get/List | primary when request is supported | capability fallback | last compatibility fallback |
| Create/Replace/Patch/Delete | primary when preview/concurrency/options are supported | capability fallback | last compatibility fallback, fail-closed options |
| Server-side apply | primary | fallback | last compatibility fallback |
| Client-side apply | unsupported | primary | last compatibility fallback |
| Client preview | unsupported | primary where protocol defines it | last compatibility fallback for mapped commands |
| Server preview | primary for managed generic API operations | supported fallback | supported fallback for mapped commands |
| Discovery | primary | fallback | no specialized semantic implementation |
| Config view | not implemented | primary | no specialized semantic implementation |
| Schema/OpenAPI | not implemented | primary | no specialized semantic implementation |
| Watch | generic Managed executor intentionally unsupported | primary specialized backend | no specialized semantic implementation |
| Logs | not implemented | primary | no specialized semantic implementation |
| Copy | not implemented | primary | no specialized semantic implementation |
| Debug | not implemented | primary | no specialized semantic implementation |
| Diagnostics | not implemented | primary | no specialized semantic implementation |
| Rollout/workloads | evaluator explicitly unsupported | primary | generic process semantic path intentionally unsupported |
| Raw kubectl command | outside routing | no generic raw RPC | explicit `Invoke-Kubectl` escape hatch |

## Tests and audits added/updated

`Tests/BackendRouting.Tests.ps1` covers the core routing matrix:

- Managed/Go/Process all `Supported` -> Managed;
- Managed `Unsupported` -> Go;
- Managed `Unavailable` -> Go;
- Managed and Go `Unsupported` -> Process;
- `Unknown` is non-executable but permits a later explicit `Supported` result;
- an execution failure after selecting Managed is not replayed on Go;
- specialized discovery/schema/log/debug/diagnostics selection uses capability evaluation;
- workload/rollout routing declines Managed and selects Go.

`Tests/BackendRoutingAudit.mjs` performs source-level architecture checks for:

- one shared Runtime router;
- absence of first-interface selection in specialized clients;
- explicit managed executor whitelist;
- Go specialized capability evaluation;
- fail-closed process compatibility guards;
- Core composition order Managed -> Go -> Process;
- no duplicate managed loader/concrete backend dependency in `Optional/KubeShell.Api`;
- Provider remaining outside the new router;
- no concrete backend references from frontend modules outside Core.

The existing Runtime/mock/source tests continue to cover preview/apply/concurrency/namespace and host protocol semantics and were wired together with the new routing tests through `Tests/Run.ps1`.

## Validation performed in this environment

The complete Node/static suite passed after using the pinned `tree-sitter` 0.25.1 and `tree-sitter-pwsh` 0.38.1 packages supplied with the project materials:

```text
npm run test:static
  Clean Architecture boundary audit passed (19 Runtime C# files).
  PowerShell module layout audit passed for 4 split modules.
  Checked 72 PowerShell files; 0 failed; 0 issue(s).
  Verb/API audit passed: 235 functions use approved verbs; root exports 104 functions and 8 aliases with no duplicates or manifest drift.
  Architecture boundary audit passed for 8 generic resource paths.
  Capability-aware backend routing audit passed.
  Kubectl IPC protocol audit passed (contract 859ffcd280d7…).

git diff --check
  passed
```

A complete runtime/toolchain test was still not possible in the available execution environment:

- `pwsh` is not installed, so Pester and the authoritative PowerShell AST parser in `Tests/Parse.ps1` could not run;
- `dotnet` is not installed, so Runtime/backend SDK compilation could not run;
- installed Go is 1.23.2 while the project pins/requires Go 1.26+ for the kubectl host.

No compiled release artifact is therefore claimed as validated by this pass. The output remains source + patch and preserves the full Pester/SDK/Go test suite for execution in the project toolchain.

## Provider status

`Optional/KubeShell.Provider` has no modified files in this change set. The routing audit also rejects accidental references from Provider to `KubeBackendRouter`, the managed backend or the Go backend adapter.

## Remaining architectural debt

The main remaining debt is validation rather than a known routing inconsistency: the complete Pester/SDK/Go 1.26 suite still needs execution in a toolchain that has the project dependencies installed. The process fallback intentionally remains conservative and does not gain specialized semantic interfaces merely to increase fallback coverage. Managed can acquire additional specialized capabilities later when their request-specific semantics can be expressed without reproducing kubectl machinery; the router no longer requires frontend or client changes for that extension.
