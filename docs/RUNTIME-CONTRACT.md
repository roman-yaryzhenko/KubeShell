# KubeShell Runtime contract

## Purpose

`KubeShell.Runtime.dll` is the stable semantic layer shared by PowerShell cmdlets and, later, `KubeShell.Provider.dll`. It describes Kubernetes operations without exposing a particular client implementation.

## Configuration boundary

Runtime owns immutable `KubeConfigSet`, `KubeProfile`, `KubeConfigurationDocument` and `KubeTargetResolver` policy. It does **not** locate, read, write, or atomically replace configuration files and does not inspect XDG/AppData/environment variables. Those are frontend/adapter responsibilities.

## Resource address

Runtime addresses server resources by `GroupVersionResource` (GVR), not by Kind. `Kind` is discovery/presentation metadata. `ResourceIdentity` adds name, namespace scope and optional subresource. Server-returned objects without `metadata.namespace` are represented with `Cluster` scope; namespaced server objects retain their explicit namespace.

Legacy PowerShell resource tokens remain accepted by transitional constructors, but backends that require exact API addressing may return `Unknown` until GVR has been resolved by discovery.

## Namespace scope

`KubeNamespaceScope` is explicit:

- `Default`: target default namespace;
- `Explicit(name)`;
- `All`: all namespaces for a namespaced collection query;
- `Cluster`: cluster-scoped resource.

`ResourceIdentity` deliberately rejects `All`: a single Kubernetes object must resolve to one concrete namespace or to cluster scope. All-namespaces navigation therefore lists with a `ResourceQuery(All)` and forms item identities only after the concrete namespace is known. `null` does not mean both “current namespace” and “cluster scoped”. Mutation payload identity validation also resolves `Default` against `KubeTarget.DefaultNamespace` when that value is known; if the target default is unresolved, a payload that names a namespace must use an explicit resource namespace so backend-specific kubeconfig defaults cannot change the meaning of the request.

## Operations

Runtime uses typed operation records. Options valid for one operation are not added as nullable properties to unrelated operations.

Current operation types:

- `KubeGetOperation`
- `KubeListOperation`
- `KubeCreateOperation`
- `KubeReplaceOperation`
- `KubeApplyOperation`
- `KubePatchOperation`
- `KubeDeleteOperation`
- `KubeWatchOperation`

## Preview and apply

`KubePreviewMode` (`None`, `Client`, `Server`) specifies where a preview is evaluated. `KubeApplyStrategy` (`ClientSide`, `ServerSide`) specifies apply ownership/merge semantics. They are separate axes.

PowerShell `WhatIf` is a frontend concern and is not represented as a preview mode.

## Concurrency

`KubeConcurrencyOptions` carries intent:

- `Default`
- `RequireUnchanged` with `ExpectedResourceVersion`
- `Force`

A backend must return `Unsupported` rather than silently weaken an unsupported policy. `IKubeResourceClient` rejects `RequireUnchanged` without `ExpectedResourceVersion` before backend selection, so a malformed concurrency request has one Runtime meaning regardless of the available adapters. SSA `ForceConflicts` remains separate.

## Backend evaluation

`IKubeBackend.EvaluateAsync` returns `KubeOperationSupport`:

- `Supported`
- `Unsupported`
- `Unavailable`
- `Unknown`

Support evaluation describes backend semantics. API discovery (`KubeResourceDescriptor`) separately describes the server resource's canonical GVR, singular/short names, categories, verbs, scope and subresources. Subresource descriptors retain their own group/version/kind/verbs because endpoints such as `/scale` can differ from the parent resource. Authorization is determined only by the server or an explicit authorization check.

## Routing and interface segregation

`IKubeOperationClient` is the semantic operation port (`Evaluate*` / `Execute*`). `IKubeResourceClient` is the narrow CRUD-oriented facade (`Get`, `Exists`, `TryGet`, `ListNames`, `Create`, `Replace`, `Apply`, `Patch`, `Delete`). `IKubeResourceExecutionClient` is the adjacent rich semantic CRUD port for frontends that must preserve `KubeExecutionResult<T>` values together with Runtime warnings and diagnostics. Both resource clients expose cancellable async operations; synchronous members on the narrow facade remain convenience wrappers for provider/cmdlet hooks that are inherently synchronous. `Create` maps directly to `KubeCreateOperation`; it does not implement create-only behavior as an `Exists` check followed by `Apply`. `Replace` similarly maps directly to `KubeReplaceOperation` rather than being rewritten as apply. The selected backend therefore uses the Kubernetes primitives atomically, and an already-existing create is surfaced as `Conflict`. `KubeOperationClient` implements the routing port; the narrow and rich resource clients share that port and a composition root may wire the narrow facade to the same rich execution client. Consumers should depend on the narrowest semantic interface that preserves the information they require.

Named resource queries fail closed if label/field selectors are also supplied, because Kubernetes GET-by-name does not evaluate selectors. `ListNames` is intentionally unavailable for all-namespaces queries because bare names lose namespace identity; callers must use `Get` and inspect each returned `KubeResource.Identity.Namespace`.

`IKubeBackendSelector` is the backend-neutral selection port; `KubeBackendRouter` is its ordered implementation. `KubeOperationClient` delegates generic selection to it. Specialized requests use `KubeCapabilityRequest<TBackend>` so the request type and required semantic port are linked by the type system. Discovery, config, schema, watch, logs, copy, debug and the segregated diagnostic clients depend on the selector port rather than inspecting backend collections or choosing the first object that implements an interface.

Configured preference is Managed KubernetesClient -> Go kubectl host -> external kubectl process. Support states have one normative meaning across implementations: `Supported` means the backend can preserve the requested semantics and all deterministic prerequisites established during evaluation have passed; `Unsupported` means the shape/options or discovered API surface are known not to support them; `Unavailable` means the mechanism or required local configuration is unusable; `Unknown` means support cannot be safely established. `Unknown` is non-executable, while any later backend may still explicitly prove `Supported`.

Selection ends before execution. Every public backend `ExecuteAsync` also self-enforces its support contract, so direct calls cannot bypass semantic guards. If execution of the selected backend fails, Runtime does not automatically replay the request on another backend. This is mandatory for mutations and keeps reads deterministic as well. The router never rewrites an operation or option set to obtain a match.

`KubeExecutionContext` is a per-operation Runtime DTO (impersonation, timeout, User-Agent, field validation and correlation metadata), separate from frontend session/target-selection state. `IKubeResourceClient` accepts it explicitly on every sync/async CRUD call; async calls additionally carry `CancellationToken`, so PowerShell Provider can bridge synchronously while a future TUI/ObjectModel remains non-blocking and cancellable. Outer consumers should normally depend on semantic clients such as `IKubeResourceClient`, not on the selector or backend collection.

## Results and errors

`KubeOperationResult` separates:

- returned resources;
- Kubernetes/API warnings;
- diagnostics.

Backend identity is routing/infrastructure provenance and is intentionally absent from the semantic result contract.

Errors use `KubeException`/`KubeError`. Those types contain backend-neutral kind/code/resource/target information only. HTTP status codes, process exit codes and stderr remain adapter details and may be exposed as structured diagnostics when useful. Credentials or full Secret payloads must not be placed in diagnostics/errors merely for tracing. Frontends map structured errors to their own error mechanisms.

`KubeResource` owns a defensive snapshot of its JSON document. The public `Document` accessor returns a clone so external mutation cannot make `Identity` disagree with the stored document.

## Watch

`IKubeWatchBackend.WatchAsync` yields `KubeWatchEvent` with `Added`, `Modified`, `Deleted`, `Bookmark`, or `Error`. Reconnect policy is backend policy; watch event semantics remain stable.

## Dependency rule

Runtime may depend on the .NET BCL/System.Text.Json only. It must not reference PowerShell, the official Kubernetes client package, kubectl process/native code, Provider, or TUI assemblies.


## Execution-target identity

`KubeTarget` preserves the selected context and ordered kubeconfig path list exactly. Runtime does not trim, deduplicate, sort, or delimiter-flatten kubeconfig paths. `KubeTargetIdentityEncoding` uses a length-prefixed structural encoding so a single path containing a separator cannot collide with a multi-path target. Source/Profile/ConfigSet/DefaultNamespace remain presentation/default metadata and do not participate in the stable execution identity.

Backends that must project the ordered list into an external delimiter-based protocol must fail closed when the protocol cannot represent a path losslessly. The kubectl-process compatibility backend applies this rule to `KUBECONFIG`.
