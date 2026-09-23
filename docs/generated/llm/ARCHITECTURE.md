# KubeShell architecture

## Design goals

KubeShell separates Kubernetes semantics from PowerShell presentation and from concrete client implementations. The shared `KubeShell.Runtime.dll` is intentionally small: cmdlets, the `Kube:` provider, and future frontends can depend on semantic contracts without acquiring a dependency on PowerShell, the official Kubernetes .NET SDK, `kubectl`, the kubectl-host IPC protocol, or Go/Kubernetes implementation packages.

The discovery-driven Provider iteration adds a frontend-neutral `KubeShell.ObjectModel` and an outer `KubeShell.Hosting` composition root. The Provider is now a PowerShell framework adapter over ObjectModel/Runtime rather than a second Kubernetes execution stack.

## Layers

```text
PowerShell cmdlets              PowerShell Provider              future TUI
        │                              │                              │
        │                              ▼                              │
        │                    KubeShell.ObjectModel ◄─────────────────┘
        │                              │
        └──────────────────────────────┼──────────────────────────────┐
                                       ▼                              │
                                KubeShell.Runtime                     │
                         semantic contracts + routing                 │
                                       ▲                              │
                                       │ constructs/wires             │
                                KubeShell.Hosting                     │
                         ┌─────────────┼──────────────┐               │
                         ▼             ▼              ▼               │
              KubernetesClient    Kubectl host    KubectlProcess      │
                         │             │              │               │
                         └─────────────┴──────────────┴──────► Kubernetes API
```

The composition order is `KubernetesClient -> Kubectl host -> KubectlProcess`. Ordering is preference, not proof of support: every semantic request must be explicitly evaluated before selection. `KubeShell.KubectlProcess` remains a compatibility backend and `Invoke-Kubectl` remains the explicit raw escape hatch; no concrete adapter is part of Runtime.

## Runtime boundary

`KubeShell.Runtime` owns only backend-neutral Kubernetes semantics:

- immutable `KubeTarget` and configuration/profile representations (persistence/path resolution stay in adapters);
- `GroupVersionResource`, resource identity/query models, explicit namespace scope and subresources (`All` is collection-query scope and is forbidden on single-resource identities);
- typed Kubernetes operations (`Get`, `List`, `Create`, `Replace`, `Apply`, `Patch`, `Delete`, `Watch`);
- preview/apply/concurrency semantics;
- `IKubeBackend`, `KubeOperationSupport`, the backend-neutral `IKubeBackendSelector`, `IKubeOperationClient`, the narrow sync/async `IKubeResourceClient`, and the richer `IKubeResourceExecutionClient` result-preserving CRUD port;
- structured results, warnings, diagnostics and errors;
- watch event contracts;
- Kubernetes wire cleanup/serialization primitives.

Runtime does **not** reference:

- `System.Management.Automation`;
- `KubernetesClient` / `k8s.*` types;
- `kubectl` process code;
- kubectl-host IPC/process/Go implementation code;
- Provider/TUI types;
- configuration-store file I/O, environment-variable lookup, or OS-specific config paths.

Runtime error values are semantic as well: process exit codes/stderr and HTTP status codes remain adapter diagnostics rather than fields on `KubeException`/`KubeError`.

See `RUNTIME-CONTRACT.md` for the detailed contract.

## Clean Architecture / SOLID boundary

The dependency rule is enforced inward toward Runtime. Runtime owns policy and stable Kubernetes semantics; ObjectModel owns frontend-neutral navigation/use-case semantics; Hosting owns concrete composition; adapters own delivery mechanisms and persistence details. In particular:

- configuration persistence is implemented by `KubeShell.Configuration`, not Runtime;
- `IKubeOperationClient` exposes semantic operation routing, `IKubeResourceExecutionClient` preserves value/warnings/diagnostics for richer frontends, and `IKubeResourceClient` exposes the smaller CRUD/resource view;
- `KubeShell.ObjectModel` depends only on Runtime and contains immutable semantic locators/nodes, lazy discovery-driven topology, navigation cache policy, mount validation and rich CRUD projection;
- `KubeShell.Hosting` is the only shared component that knows the Managed -> Go -> Process composition policy and router;
- concrete backend diagnostics may mention HTTP/process details, but Runtime errors do not depend on those mechanisms;
- `KubeResource` owns an immutable snapshot of its document and returns defensive copies of the mutable JSON DOM;
- the managed backend is decomposed by session/configuration, discovery, execution, and response mapping responsibilities.

`System.Text.Json` remains an intentional Runtime dependency because an unstructured Kubernetes object is itself a JSON-shaped domain value, especially for CRDs. Filesystem/network/process SDKs remain outside the core.

## Backend support evaluation

Capabilities are not represented by one global flags enum. `IKubeBackendSelector` is the selection port and `KubeBackendRouter` is its ordered implementation. Generic operations use `IKubeBackend.EvaluateAsync`; specialized semantic interfaces use typed `KubeCapabilityRequest<TBackend>` requests plus the backend-neutral `IKubeCapabilityEvaluator` companion contract:

```text
KubeOperation + KubeTarget + KubeExecutionContext
                         │
                         ▼
                 IKubeBackend.EvaluateAsync
                         │
       Supported | Unsupported | Unavailable | Unknown
```

The distinction matters:

- `Unsupported`: the request shape/options or discovered API surface are known not to support the requested semantics;
- `Unavailable`: the backend mechanism or required local configuration is not usable;
- `Unknown`: support cannot be established safely with the information available;
- `Supported`: the backend can preserve the requested semantics and the deterministic prerequisites checked during evaluation have passed. It is not a promise that the subsequent API operation succeeds.

Routing preference is separate from support. `Supported` selects that backend; `Unsupported` and `Unavailable` allow examination of the next backend; `Unknown` is fail-safe and is never executable, although a later backend may still explicitly report `Supported`. Once a `Supported` backend begins execution, transport/API failure is not converted into another-backend retry because a mutation may already have reached the server. There is no semantic weakening: client preview is never silently changed to server preview, and client-side apply is never rewritten as server-side apply.

Server resource discovery is a separate fact source (`KubeResourceDescriptor`: canonical GVR, aliases/categories, verbs, scope and detailed subresources). RBAC authorization is also separate from capability support.

## Managed backend

`Backends/KubeShell.KubernetesClient` adapts Runtime operations to the unchanged official `KubernetesClient` NuGet package, pinned to `19.0.2`. The public `KubernetesClientBackend` is intentionally thin: session creation, discovery/cache, generated-API execution, request context, and response/error translation are separate internal components so each has one primary reason to change.

It uses generated `CustomObjects` API methods rather than reimplementing HTTP routing. It covers the API-server side of the model:

- generic CRUD for built-in and custom resources;
- server dry-run (`dryRun=All`);
- server-side apply (`application/apply-patch+yaml`);
- `fieldManager`, `fieldValidation`, and SSA conflict forcing;
- kubeconfig/authentication handled by the official client;
- API discovery with a backend-local discovery cache;
- warning headers mapped to structured Runtime warnings.

It explicitly does not claim client-side preview, client-side apply, workload/rollout helpers, watch, logs, copy, debug, schema, config-view or diagnostics until those Runtime semantics are implemented directly. Unsupported shapes fall through to the Go backend; the managed evaluator fails closed for operation types its executor does not implement.

### Effective routing by semantic group

| Semantic group | Primary | Fallback | Process compatibility |
| --- | --- | --- | --- |
| Generic get/list/create/replace/patch/delete | Managed when requested options are supported | Go host | Yes, if its evaluator reports `Supported` |
| Server-side apply / server dry-run | Managed | Go host | Yes |
| Client-side apply / client preview | Go host | none semantic | Last-resort only where the process evaluator explicitly supports the exact shape |
| Discovery | Managed | Go host | No specialized process interface |
| Config view / schema | Go host | none | No specialized process interface |
| Watch / logs / copy / debug | Go host | none | No ordinary semantic process fallback |
| Diagnostics | Go host | none | No specialized process interface |
| Rollout / workload operations | Go host | none | Process backend reports these operation types unsupported |

Manifest commands reduce to the typed operations above, so their actual backend depends on apply strategy, preview and concurrency options rather than on a separate manifest-specific transport.

## kubectl process compatibility backend

`Backends/KubeShell.KubectlProcess` contains the external process execution previously embedded in Runtime. It remains an ordered compatibility fallback for generic Runtime operations and supports the explicit `Invoke-Kubectl` escape hatch. Ordinary cmdlets no longer depend on it for logs, copy, discovery, schema, workloads, manifests or diagnostics.

Interactive `attach`/`exec` and `port-forward` use narrowly scoped short-lived workers from the bundled `kubeshell-kubectl-host`; debug mutation itself stays on the typed semantic RPC path. Those workers are intentionally distinct from the external process backend and reject generic kubectl commands. The Provider now consumes `KubeShell.ObjectModel` and Runtime semantic clients supplied by `KubeShell.Hosting`; it neither invokes kubectl directly nor participates in backend selection.

## Target and execution context

`KubeTarget` answers *where and under which configured Kubernetes identity* an operation runs. Frontends resolve the kubeconfig-path/context selection before routing. Both managed and kubectl backends receive the same immutable target, preventing different backends from independently selecting different environment/current-context state. Credential material itself remains backend-owned rather than being copied into Runtime.

`KubeExecutionContext` contains per-call execution settings such as impersonation, timeout, User-Agent, field-validation preference and correlation identifier. Backends must not mutate a shared target/configuration in order to apply per-call settings.

## Namespace semantics

A nullable namespace string is not used as a multi-purpose sentinel. Runtime distinguishes:

```text
Default   use the resolved target default namespace
Explicit  use the supplied namespace
All       all namespaces for a namespaced resource
Cluster   cluster-scoped resource
```

Discovery/frontends are responsible for resolving whether a resource is namespaced. The managed API frontend uses discovery before dispatch so cluster-scoped resources are not sent to namespaced endpoints.

## Apply and preview

Apply strategy and preview location are independent concepts:

```text
Apply strategy: ClientSide | ServerSide
Preview:        None | Client | Server
```

Invalid combinations are rejected before routing. In particular, client preview is not a valid variant of server-side apply. SSA conflict forcing is distinct from optimistic concurrency policy.

PowerShell `-WhatIf` is also separate: it prevents the frontend from invoking a mutation. Kubernetes server preview performs a real API request with `dryRun=All` and therefore is not PowerShell `WhatIf`.

## Concurrency

Runtime carries intent rather than one mandatory policy:

```text
Default
RequireUnchanged(expected resourceVersion)
Force
```

Backends may reject policies whose semantics they cannot guarantee. SSA `ForceConflicts` remains an apply-specific option and is not the same as optimistic-concurrency `Force`.

## Watch model

Watch is modeled as an event stream, not merely a stream of resources:

```text
Added | Modified | Deleted | Bookmark | Error
```

`IKubeWatchBackend` is separate from ordinary `ExecuteAsync` so reconnect, cancellation and streaming lifetime do not distort CRUD contracts.

## Cache boundaries

Three caches are conceptually distinct:

- backend/API discovery cache;
- resource/list data cache;
- ObjectModel/Provider navigation cache.

The cache layers have separate ownership. `KubeShell.Api` maintains a small projected discovery cache over backend discovery. `KubeShell.ObjectModel` owns a separate semantic-locator keyed topology cache and never reaches into a backend-specific cache API. Resource collections remain live by default. Provider `-Refresh` invalidates the relevant navigation entry and propagates the semantic discovery request as `refresh=true`; each selected backend is responsible for obtaining a discovery snapshot that does not reuse its pre-refresh cached result.

## Result, bulk and redaction semantics

Runtime operations are single-target operations. PowerShell pipeline/batch orchestration remains above Runtime so partial success keeps normal per-object PowerShell semantics rather than becoming an artificial all-or-nothing batch.

`KubeOperationResult` keeps resources, Kubernetes/API warnings and backend diagnostics distinct. Errors use structured `KubeException`/`KubeError`. Diagnostic/error paths must not echo bearer tokens, private keys, full kubeconfigs, exec-plugin credentials, or Secret payloads merely for tracing; normal operation results may still contain Secret resources when explicitly requested.

## Version skew and backend equivalence

Cluster version, official C# client version and future client-go/kubectl-shim version are independent. Runtime does not require version equality; each backend evaluates the concrete requested operation and reports support. Versions are diagnostic metadata, not routing keys.

Operations supported by more than one backend should share contract tests against the same cluster. Equivalence is semantic rather than byte-for-byte: server-owned fields, resourceVersion, timestamps, managedFields ordering and similar metadata may differ.

## PowerShell boundary

PowerShell remains responsible for:

- pipeline semantics;
- `PSTypeNames` and computed presentation properties;
- formatting and completion;
- `ShouldProcess`, `-WhatIf`, `-Confirm`;
- `KubeShell.ChangeResult`;
- user-facing session/profile commands;
- translation from `KubeException` to `ErrorRecord`.

Runtime receives no PowerShell types.

### Internal PowerShell module layout

`KubeShell.Core`, `KubeShell.Shell`, `KubeShell.Configuration`, and `KubeShell.Operations` remain single PowerShell module boundaries. Their implementation is physically split under `Private/*.ps1` by reason to change and dot-sourced into the parent module scope. This keeps script state, Pester mocking seams, and exported command semantics unchanged while avoiding multi-responsibility monolithic `.psm1` files. The parent `.psm1` files are bootstrap/export files only.

The split is intentionally physical rather than architectural: no extra public modules or dependency edges are introduced. `Resources`, `Diagnostics`, `Manifests`, and the optional modules remain unsplit until their internal cohesion justifies a similar change.

## Provider/ObjectModel boundary

`Optional/KubeShell.Provider` depends on `KubeShell.ObjectModel`, Runtime and Hosting. It is a thin `NavigationCmdletProvider` adapter: PSDrive lifecycle/dynamic parameters, path-segment traversal, `ShouldProcess`, PowerShell `Force`, projection, and `ErrorRecord`/warning/verbose output remain at this boundary. It does not receive backend arrays/router objects, invoke kubectl/process APIs, or call cmdlets through nested runspaces.

`KubeShell.ObjectModel` owns discovery-driven topology and semantic navigation independently of PowerShell. Stable `KubeNodeLocator` values distinguish TargetRoot, NamespacesRoot, Namespace, ClusterRoot, ResourceCollection, AllNamespaces ResourceNamespaceBucket and ResourceItem. Collection identity is version-neutral `GroupResource + Scope`; preferred GVR is resolved through discovery when an operation runs. CRDs therefore appear without Provider changes.

AllNamespaces is represented as namespace buckets rather than a flattened list so equal object names in different namespaces stay unambiguous. PSDrive roots select a semantic RootLocator for target, namespace, cluster-scoped collection, namespace-scoped collection or all-namespaces collection; PowerShell path strings never become domain identity/cache keys.

Provider mutations project `New-Item -> Create` (or explicit frontend `-Force` upsert via Apply), `Set-Item -> Apply`, and `Remove-Item -> Delete`. Rich Runtime warnings/diagnostics survive through ObjectModel and are projected by the Provider. See `PROVIDER-CONTRACT.md`.

## kubectl-faithful host backend

Client-side apply, true kubectl client preview, contextual REST mapping, and future kubectl-local streaming semantics live in a separate backend:

```text
KubeShell.Kubectl.dll
        │
        │ versioned framed IPC (redirected stdio by default)
        ▼
kubeshell-kubectl-host
        │
        ├── k8s.io/kubectl
        ├── k8s.io/cli-runtime
        └── k8s.io/client-go
```

The Go process is long-lived for the module/backend lifetime. It owns opaque sessions, discovery/RESTMapper caches, request multiplexing, operation handles, and stream state. A helper restart increments the managed generation; cached session handles from an older generation are discarded and recreated.

This boundary is intentionally a process protocol rather than `c-shared`/PInvoke. Current .NET guidance does not support Go for in-process interoperability, and process isolation also prevents a Go panic/runtime failure from terminating PowerShell. `KubeShell.KubectlProcess` remains a separate ordered compatibility backend.

The protocol is KubeShell-owned; Kubernetes Go structures never cross it. GVR/scope/options/handles remain typed envelope fields while Kubernetes resources and Status objects use their natural JSON wire representation. See `KUBECTL-HOST-PROTOCOL.md`; `NATIVE-BACKEND-ABI.md` records the superseded experimental C ABI direction.

## Verification boundaries

The source tree has independent gates for:

1. PowerShell syntax/AST parsing;
2. approved verbs/public surface;
3. generic resource paths crossing the Runtime boundary;
4. Runtime assembly dependency isolation;
5. Runtime semantic contract tests;
6. managed backend source-boundary tests;
7. existing cmdlet/mock/configuration tests;
8. capability-aware routing/composition source audit and routing regression tests;
9. cross-language kubectl-host protocol/hash/method audits and Go frame/server tests;
10. Provider/ObjectModel dependency and forbidden-coupling static audit;
11. cluster-free ObjectModel fixture covering discovery, aliases, mounts, AllNamespaces, cache/refresh, CRUD and cancellation when .NET is available;
12. optional-module tests when the managed NuGet backend is built;
13. live Kubernetes integration as a separate opt-in layer.
