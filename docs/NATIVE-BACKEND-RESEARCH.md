# kubectl-faithful backend research and production decision

Status: implemented direction introduced in `0.3.0-alpha10.9-ipc` and retained in `0.3.0-alpha11`.

## Decision summary

The ecosystem review did **not** find a maintained stable C ABI that exposes the required kubectl semantics (client-side apply, client dry-run, resource-builder/RESTMapper behavior, discovery, and eventually streaming) to .NET. Upstream `k8s.io/kubectl`, `k8s.io/cli-runtime`, and `k8s.io/client-go` are the correct semantic implementation source, but they expose Go APIs whose compatibility follows the Kubernetes module line rather than a stable FFI contract.

The first prototype therefore used Go `-buildmode=c-shared` behind a KubeShell-owned C ABI. A second research pass changed the production decision: current .NET native-interop guidance explicitly states that Go is not supported for **in-process** interoperability because Go runtime signal-stack requirements are not met by .NET, and recommends a Go-hosted process with IPC. See:

- https://learn.microsoft.com/dotnet/standard/native-interop/abi-support
- https://github.com/dotnet/docs/blob/main/docs/standard/native-interop/abi-support.md

The production architecture is consequently:

```text
KubeShell.Runtime
      |
      v
KubeShell.Kubectl.dll
      |  versioned local IPC
      v
kubeshell-kubectl-host (Go process)
      |
      +-- k8s.io/kubectl
      +-- k8s.io/cli-runtime
      +-- k8s.io/client-go
```

`KubeShell.KubectlProcess` remains a separate ordered compatibility fallback. The earlier c-shared proof remains experimental only.

## Existing-solution survey

### `kubernetes/kubectl`

Repository: https://github.com/kubernetes/kubectl  
License: Apache-2.0  
Language/API: Go packages plus CLI.

Useful properties:

- authoritative implementation of kubectl apply and command-local semantics;
- `pkg/cmd/apply` exposes `ApplyFlags`, `ApplyOptions`, validation, OpenAPI/schema machinery, last-applied behavior, strategic merge, and server-side apply integration;
- designed to be consumed by kubectl and Go code, not as a stable C/.NET ABI.

Risks:

- internal/public Go package shape may change with Kubernetes releases;
- command constructors may reach `cmdutil.CheckErr`/process-exit paths and are unsuitable as a library boundary;
- therefore KubeShell calls option/factory APIs directly and pins one Kubernetes minor line.

### `kubernetes/cli-runtime`

Repository: https://github.com/kubernetes/cli-runtime  
License: Apache-2.0  
Language/API: Go.

Useful properties:

- resource builder, generic CLI options, RESTClientGetter/factory integration, discovery/mapping helpers;
- provides kubectl-style resource/discovery infrastructure.

Risk: it does not promise a stable cross-version API and is deliberately kept behind the Go host adapter.

### `kubernetes/client-go`

Repository: https://github.com/kubernetes/client-go  
License: Apache-2.0  
Language/API: Go.

Useful properties:

- REST configuration/transports;
- typed/dynamic clients;
- discovery and cached discovery;
- RESTMapper integration;
- watch/exec transport primitives.

It is the correct foundation for API operations, but it is not kubectl apply/client-dry-run semantics by itself and exposes no maintained C ABI.

### Official Kubernetes C client

Repository: https://github.com/kubernetes-client/c  
License: Apache-2.0.

This is a Kubernetes REST client, not an embedded kubectl implementation. It does not solve client-side apply, kubectl client dry-run, resource.Builder behavior, or the desired kubectl semantic fidelity. It would add another client implementation while losing the reason for introducing the backend.

### Official Kubernetes C# client

Repository: https://github.com/kubernetes-client/csharp  
NuGet: `KubernetesClient`.

KubeShell already has this as the separate `KubeShell.KubernetesClient` backend. It is appropriate for managed Kubernetes API semantics, including server-side operations. Reimplementing kubectl client-side behavior on top of it would duplicate rapidly changing kubectl code and remains intentionally out of scope.

### Rust/C/C++ bridges and generic Go FFI generators

Generic bridges can generate or simplify C/PInvoke glue, but no maintained project found in the survey provides the required kubectl semantic surface as a stable .NET-facing ABI. More importantly, code generation does not remove the CoreCLR + Go-runtime coexistence problem; it only automates the same in-process boundary.

### Poor-discoverability/PoC search

Searches covered combinations of `kubectl`, `client-go`, `cgo`, `//export`, `buildmode=c-shared`, P/Invoke, FFI, `libkubectl`, Rust bridges, NuGet wrappers, SIG CLI issues/repositories, and PowerShell/Kubernetes projects. Small and abandoned examples demonstrate Go shared-library mechanics, but none provides a maintained kubectl/client-go ABI with client-side apply/dry-run and discovery semantics suitable for KubeShell.

This is negative ecosystem evidence, not a proof that no private or unindexed implementation exists.

## Transport comparison

| Criterion | Go c-shared + P/Invoke | long-lived Go host + IPC | framed helper per process lifetime | external kubectl per command | reimplement in C# |
|---|---|---|---|---|---|
| kubectl semantic fidelity | excellent | excellent | excellent | exact CLI | weakest for local kubectl behavior |
| process startup | none after load | once per module/backend lifetime | once | every command | none |
| per-call overhead | lowest | small local framing cost | small | process cost | lowest |
| crash isolation | poor | strong | strong | strong | n/a |
| .NET/Go runtime support | unsupported in-process | supported process boundary | supported | supported | managed only |
| cancellation | custom ABI handles | correlation + operation handles | same | process kill/CLI | native managed |
| watch/exec/streams | possible but awkward ABI | natural framed streams | natural | proven CLI | significant work |
| upgrades | native ABI + Go library | replace helper behind protocol | same | kubectl binary | managed release |
| debugging/leak isolation | mixed runtime | strong | strong | strong | strong |
| portability | native library/RID | helper/RID | helper/RID | kubectl install | assembly |

For Kubernetes operations, local IPC overhead is dominated by API-server/network/discovery latency. The process boundary therefore trades negligible practical latency for a materially safer runtime boundary.

## Why stdio framing is the packaged default

Redirected stdin/stdout gives a private full-duplex byte stream to one child process and behaves consistently on Linux, macOS, and Windows. It requires no socket-path lifecycle or platform-specific named-pipe adapter. The protocol is transport-neutral; Unix-domain-socket mode exists for diagnostics and can be extended with named pipes later without changing Runtime or kubectl adapters.

This is not the existing process backend model: `kubeshell-kubectl-host` is started once, holds sessions/discovery caches, multiplexes concurrent requests, and owns long-lived watch state. It never invokes `kubectl` internally.

## Semantic mapping

The Runtime operation is preserved exactly. No router/backend may silently substitute:

```text
Client preview -> Server preview
Client-side apply -> Server-side apply
```

Protocol-v1 mapping:

| Runtime | host implementation |
|---|---|
| Get | dynamic client GET after REST mapping |
| List | dynamic client LIST after REST mapping |
| Create | dynamic client CREATE; server dry-run where requested |
| Replace | dynamic client UPDATE; resourceVersion precondition where requested |
| Delete | dynamic client DELETE; delete precondition/force/grace where defined |
| Patch | dynamic client PATCH; no invented generic resourceVersion precondition |
| Apply (CSA) | upstream kubectl apply options/client-side apply machinery |
| Apply (SSA) | upstream kubectl apply options/server-side mode |
| Watch | dynamic client WATCH behind operation handle/stream frames |

Client preview for generic create/replace/delete/patch remains `Unsupported` rather than being approximated. Kubectl-faithful client preview is currently provided for apply, where upstream has the required machinery.

## Upstream apply embedding

The reviewed Kubernetes 0.37 path is:

```text
cmdapply.NewApplyFlags(streams)
flags.AddFlags(command)
flags.ToOptions(factory, command, "KubeShell", nil)
options.Validate()
options.Run()
```

KubeShell supplies in-memory JSON through `-f -` and requests JSON output. It deliberately does not call `NewCmdApply`, `cmdutil.CheckErr`, or execute a kubectl subprocess. This keeps errors in ordinary Go return values rather than permitting a CLI-level path to terminate the helper process.

The factory uses request-specific REST configuration plus real cached discovery/RESTMapper/OpenAPI plumbing, so kubectl retains ownership of last-applied annotations, strategic-merge decisions, OpenAPI validation, field manager behavior, and related implementation details.

## Session/discovery model

Runtime resolves targets above the backend. `SessionCreate` explicitly carries kubeconfig paths, selected context, and namespace default. The host refuses an empty path set and does not inspect ambient `KUBECONFIG` or the home-directory default.

Sessions are concurrency-safe. Base config is immutable after construction; per-call timeout, user-agent, impersonation, field-validation/correlation context are applied to copies. Discovery/RESTMapper caches are keyed by security-relevant request context and can be refreshed independently from resource state.

GVR is primary identity. RESTMapper may resolve aliases/version-less input; responses return canonical GVR so the managed Runtime value remains truthful.

## Cancellation/streaming model

Short requests use frame correlation IDs and can be cancelled while in flight. Long-lived operations use distinct opaque operation IDs. Watch returns such a handle and streams data after the start request completes. Closing a session cancels its operations; host shutdown cancels/join in-flight work and closes all operation state.

This is intentionally the future shape for exec, log-follow and port-forward: adding stream channel/direction metadata does not require converting the protocol into a single forever-blocking RPC.

## Kubernetes module policy

The host pins one coherent module minor line. For this snapshot:

```text
k8s.io/kubectl      v0.37.0
k8s.io/cli-runtime  v0.37.0
k8s.io/client-go    v0.37.0
k8s.io/apimachinery v0.37.0
```

The uploaded upstream `go.mod` files declare Go 1.26.0, so build scripts require Go 1.26+. Kubernetes/client module versions are diagnostic implementation details and do not determine KubeShell protocol compatibility.

Upgrade policy:

1. change all Kubernetes modules coherently;
2. compile against the new upstream line;
3. rerun protocol/frame tests;
4. run discovery/RESTMapper/CRD tests;
5. run CRUD/server-dry-run tests;
6. run CSA/SSA/client/server-preview regression tests;
7. run watch/cancellation/restart tests;
8. test supported Kubernetes server-version skew;
9. change the KubeShell protocol only if the neutral contract itself must change.

## Production conclusion

The reusable upstream base is **Go kubectl/cli-runtime/client-go**, but no suitable stable external ABI was found. The stable boundary is therefore owned by KubeShell as a process protocol rather than a C ABI. This preserves kubectl semantic fidelity while keeping Go runtime failures and upstream API churn outside the PowerShell/CoreCLR process.
