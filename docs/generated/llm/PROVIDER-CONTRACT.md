# Future generic Provider/object contract

Status: implemented architectural contract for the discovery-driven Provider/ObjectModel iteration. TUI/watch/editor-specific surfaces remain deferred.

## SHiPS principles retained

The future generic layer should retain the useful parts of SHiPS:

- container/leaf node model;
- lazy child discovery;
- cacheable navigation with explicit refresh;
- ability to mount a drive at an arbitrary subtree/root;
- domain logic separated from provider/navigation machinery.

It should not reproduce SHiPS nested-runspace execution. KubeShell Provider will be C# and call Runtime directly.

## Navigation contract

Implemented core types:

```text
KubeNodeLocator (immutable semantic identity)
  TargetRoot | NamespacesRoot | Namespace | ClusterRoot
  ResourceCollection | ResourceNamespaceBucket | ResourceItem

KubeNavigationNode
  Id / Locator / Name / DisplayName / Kind / Value / Metadata / Capabilities

IKubeNavigationService
  GetChildrenAsync / GetChildNamesAsync / ResolveChildAsync / GetItemAsync
  CreateRootLocatorAsync / ResolveResourceAliasAsync / CreateAsync / ApplyAsync / DeleteAsync
```

Provider path is navigation/presentation, not domain identity. Kubernetes label/field selectors are query parameters, not encoded into path syntax.

Provider navigation cache is separate from Kubernetes discovery and resource caches.

## Operation contract

Richer operations are described generically rather than by Kubernetes-specific TUI code:

```text
ObjectOperationDescriptor
ObjectOperationVariantDescriptor
ObjectOperationParameterDescriptor
ObjectOperationRequest
ObjectOperationResult
ObjectOperationMessage
ObjectChangeSummary
```

A conceptual provider interface is:

```text
GetOperations(ObjectReference)
Invoke(ObjectReference, ObjectOperationRequest)
```

How this is surfaced through PowerShell is deliberately deferred; `NavigationCmdletProvider` instances are not themselves a convenient public discovery API.

## Capabilities vs availability

Generic operation availability is distinct from Kubernetes backend support.

For example the Kube provider may expose:

```text
Preview
  Server  available
  Client  unavailable (native client backend not installed)
```

The generic consumer sees operation descriptors/availability. It does not see `KubePreviewMode`, `IKubeBackend`, or native ABI feature bits.

## WhatIf

`SupportsWhatIf`, mutation status and confirmation requirements are generic operation metadata, but PowerShell `ShouldProcess` remains enforced by the Provider for provider mutations. A Kubernetes server preview is a real operation and must not be conflated with `WhatIf`.


## Provider CRUD semantics

Provider item mutations should project PowerShell semantics onto Runtime resource primitives rather than emulate them with preflight races:

- `New-Item` -> `IKubeResourceClient.Create` for atomic create-only behavior;
- `Set-Item` -> `IKubeResourceClient.Apply` for assignment/upsert behavior;
- `Remove-Item` -> `IKubeResourceClient.Delete`.

`New-Item` must not be implemented as `Exists` followed by `Apply`; that would introduce a time-of-check/time-of-use race. PowerShell `-Force`, if supported for an existing item, is a frontend policy and must not be confused with Kubernetes server-side-apply force-conflict ownership.


## Implemented discovery and mount semantics

Resource collection identity is `GroupResource + Scope`; preferred API version is resolved at operation time. Discovery drives built-in and CRD collection nodes, and aliases accept canonical `resource.group`, plural, singular, Kind and short name only when the match is unambiguous.

All-namespaces mounts expose virtual namespace buckets, preserving namespace in every concrete `ResourceItemLocator`. Persistent navigation locators never retain `Default` scope: collections use cluster, all-namespaces, or an explicit namespace, while concrete items use only cluster or an explicit namespace. The all-namespaces collection root is not directly creatable; a namespace bucket is the creatable container once namespace identity is concrete. Namespace mounts do not require a successful cluster-wide namespace list, so direct RBAC-limited navigation remains possible. PSDrive roots store semantic locators, not PowerShell paths.

## Cache and refresh

ObjectModel caches only topology nodes that are safe to reuse (target/namespace/cluster resource-kind topology). Kubernetes resource collections and AllNamespaces buckets use live resource-data semantics. Provider `Get-ChildItem -Refresh` invalidates the relevant ObjectModel navigation entry and propagates a semantic `refresh=true` discovery request. ObjectModel never calls a backend-specific cache invalidation API; the backend owns how it satisfies the fresh-discovery contract.

Preferred-version resolution and discovery freshness are separate contracts. Persistent locators remain version-neutral and resolve a concrete preferred GVR when an operation needs one, but an ordinary read/navigation operation may resolve against the current cached discovery snapshot. Explicit topology refresh requests fresh discovery. Mutations may deliberately request fresh preferred discovery before execution as a stronger safety policy. A cached read using a still-served older preferred version is therefore not, by itself, a violation of the version-neutral locator contract; freshness requirements are governed by the refresh/cache contract.

## Frontend boundary

The Provider blocks on async ObjectModel calls only at the synchronous `NavigationCmdletProvider` boundary. ObjectModel remains async-first and cancellation-aware for a future TUI. Basic operation descriptors are frontend-neutral placeholders for later generic operation discovery; no TUI framework or PowerShell type crosses into ObjectModel.
