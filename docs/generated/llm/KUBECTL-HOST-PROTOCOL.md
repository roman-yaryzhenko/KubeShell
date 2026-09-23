# kubeshell-kubectl-host protocol v1

## Purpose and boundary

`KubeShell.Kubectl.dll` is a managed Runtime adapter. `kubeshell-kubectl-host` is a long-lived Go process that embeds upstream kubectl/cli-runtime/client-go. The protocol between them is KubeShell-owned and intentionally independent of Go/Kubernetes structs.

```text
PowerShell cmdlets
      |
      v
KubeShell.Runtime (neutral typed operations)
      |
      v
KubeShell.Kubectl.dll
      |  framed IPC (stdio by default)
      v
kubeshell-kubectl-host
      |
      +-- k8s.io/kubectl v0.37.0
      +-- k8s.io/cli-runtime v0.37.0
      +-- k8s.io/client-go v0.37.0
```

Runtime does not know the transport. The Go host does not know PowerShell.

## Frame

Every frame starts with a 24-byte little-endian header:

```text
uint32 magic             0x4b534831 (KSH1)
uint16 protocol_major
uint16 protocol_minor
uint16 message_kind
uint32 flags
uint64 correlation_id
uint16 payload_length    0xffff => an additional uint32 length follows
```

Payloads are capped at 64 MiB. The extended length form avoids penalizing ordinary small control messages while allowing Kubernetes JSON documents larger than 64 KiB.

Message kinds are `Hello`, `HelloAck`, `Request`, `Response`, `Error`, `StreamItem`, `StreamEnd`, `Cancel`, `Shutdown`, `Ping`, and `Pong`. JSON is used for envelopes because Kubernetes resources are naturally JSON and the boundary is local/private; the binary frame keeps message delineation, correlation, and size validation outside JSON.

## Negotiation

The first frame must be `Hello`. The client sends a minimum/maximum protocol range and the SHA-256 contract fingerprint. The host fails closed when there is no protocol intersection or the fingerprint differs. Only after `HelloAck` may operational frames be sent.

`HelloAck` reports:

- selected protocol major;
- feature bitmap;
- host build version;
- embedded kubectl/client-go versions;
- contract fingerprint.

Feature bits are backend implementation detail used by `EvaluateAsync`; they are not exposed as a Runtime-wide flags enum.

## Methods

Protocol-v1 method IDs are stable:

| ID | Method |
|---:|---|
| 1 | SessionCreate |
| 2 | SessionClose |
| 3 | DiscoverAPIVersion |
| 4 | ResolveResource |
| 5 | DiscoverPreferred |
| 100 | Get |
| 101 | List |
| 102 | Create |
| 103 | Replace |
| 104 | Delete |
| 105 | Patch |
| 106 | Apply |
| 107 | WatchStart |
| 108 | LogsStart |
| 200 | Explain |
| 201 | RolloutUndo |
| 202 | RolloutRestart |
| 203 | Scale |
| 204 | SetImage |
| 205 | RolloutStatus |
| 300 | ConfigView |
| 400 | AccessReview |
| 401 | PodMetrics |
| 402 | NodeMetrics |
| 403 | DnsProbe |
| 500 | Copy |

New methods must receive new IDs. Existing IDs never change meaning inside protocol major 1.

## Sessions

A session is an opaque `uint64` owned by the host. `SessionCreate` receives explicit kubeconfig paths, selected context, and the Runtime-resolved default namespace. The host refuses a session with no kubeconfig paths and never falls back to `KUBECONFIG` or `~/.kube/config`.

Sessions own immutable base REST configuration plus discovery/RESTMapper caches. Per-call execution options copy the REST config; shared session state is not mutated. Managed session-cache keys include helper-process generation, so a restarted helper can never reuse a stale native handle.

Namespace scope is tagged, not nullable:

```text
default
explicit(name)
all
cluster
```

## Execution context

Each operation carries timeout, user-agent, field-validation policy, correlation/tracing identifier, and optional impersonation (user, UID, groups, extras). The Go adapter creates/copies request configuration per call.

The correlation identifier is application metadata; transport correlation uses the frame's independent numeric `correlation_id`.

## Resource identity and discovery

GVR is the primary address. Kind/GVK are discovery metadata. A resource request contains GVR, tagged namespace scope, optional name, and optional subresource.

The host uses real discovery and contextual RESTMapper APIs. Resolution returns the **canonical resolved GVR**, preventing aliases/short names/version-less input from leaking back into Runtime as false identity. Descriptors contain GVR, GVK where discoverable, namespaced flag, verbs, singular name, short names, categories, and discoverable subresources/verbs/GVK.

Discovery cache invalidation is independent of resource data. A refresh discards the relevant discovery/RESTMapper bundle and rebuilds it.

## Ordinary operations

GET/LIST/CREATE/REPLACE/DELETE/PATCH use `client-go/dynamic` after REST mapping. Kubernetes resources cross the boundary as JSON only. Create/replace validate payload GVK against the RESTMapper-resolved GVK. Server preview uses API-server dry-run. Unsupported client-local semantics fail closed rather than being approximated.

Optimistic concurrency is preserved where Runtime defines a concrete Kubernetes representation: replace sets the expected `resourceVersion`; delete uses a resourceVersion precondition. Generic patch concurrency modes without a portable representation are unsupported.

## Apply

Apply remains upstream-owned. For every apply call the host constructs fresh upstream kubectl apply options and uses:

```text
ApplyFlags
  -> ToOptions(factory, command, "KubeShell", ...)
  -> Validate()
  -> ApplyOptions.Run()
```

The host deliberately does not run `NewCmdApply`, `cmdutil.CheckErr`, or a kubectl subprocess; those command-level paths may terminate a process. The adapter supplies in-memory `-f -` JSON and `-o json`.

This preserves upstream client-side apply, last-applied annotation, OpenAPI/schema validation, strategic-merge behavior, SSA, field manager, conflict forcing, and client/server dry-run behavior without copying kubectl implementation details into KubeShell.

No semantic fallback is allowed: client preview is distinct from server preview; client-side apply is distinct from server-side apply.

## Higher-level semantic services

Protocol v1 also exposes typed services above generic CRUD:

- preferred-resource discovery and kubeconfig context view;
- OpenAPI v3 schema/explain as structured schema DTOs rather than rendered CLI text;
- rollout undo/restart/status, scale and image mutation, with kubectl polymorphic helpers retained where they define workload semantics;
- access review, Metrics API reads and DNS probing through Kubernetes APIs;
- pod log streaming through the operation-handle stream channel;
- pod copy through upstream kubectl `cp.CopyOptions` without a kubectl subprocess.

YAML serialization is intentionally **outside** this protocol. `KubeShell.Serialization.dll` owns local managed YAML/JSON conversion and manifest canonicalization.

## Cancellation and streaming

Numeric frame correlation IDs identify short requests. `Cancel{correlationId}` cancels an in-flight short request. Long-lived operations receive a distinct opaque operation ID. `Cancel{operationId}` cancels that operation after the start request has completed.

`WatchStart` and `LogsStart` return an operation ID, then emit `StreamItem` frames and exactly one terminal `StreamEnd`. Cancellation targets the operation handle after the start request has completed. Interactive `exec` and `port-forward` deliberately use narrowly scoped bundled workers instead of pretending terminal/local-listener byte streams are ordinary resource RPCs.

All writes are serialized by the host. Requests may execute concurrently. Session discovery caches are mutex-protected; dynamic REST clients/config copies are per operation. Closing a session cancels its long-lived operations first. Host shutdown cancels/join short requests and closes all operation/session state.

## Errors

`Error` frames contain a stable class/code/message plus optional Kubernetes `Status` JSON, HTTP status, retryability, and diagnostics. Managed code maps classes into neutral `KubeErrorKind`; HTTP/client-go details remain backend diagnostics.

Support evaluation distinguishes:

- backend feature availability;
- discovery/resource mapping;
- API-advertised resource verbs;
- authorization/authentication, which generally leave support `Unknown`;
- process/transport/configuration availability.

## Transport and lifecycle

Packaged mode uses redirected stdio. There is no shell and no textual protocol. A single adapter instance owns one helper process for the lifetime of `KubeShell.Core`; module removal disposes it. If the helper exits, the next operation starts a new generation and sessions are recreated.

Unix-socket mode exists for diagnostics/external-host experiments. The protocol itself is transport-neutral and can later run over named pipes or another local byte stream without changing Runtime or Kubernetes adapters.

## Versioning policy

Protocol/contract versioning is independent from Kubernetes module versions. `k8s.io/kubectl`, `cli-runtime`, `client-go`, and `apimachinery` are pinned to one coherent minor line inside the host and may be replaced behind this protocol. Upstream upgrades require compile, protocol, discovery, mutation, apply/dry-run, watch/cancellation, and skew regression tests before release.
