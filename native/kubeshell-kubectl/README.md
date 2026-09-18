# kubeshell-kubectl-host

This directory contains the Go side of the kubectl-faithful KubeShell backend. Production code is a **long-lived helper process**, not a Go `c-shared` library loaded into PowerShell.

## Layout

- `internal/protocol` — transport-neutral versioned frame/envelope contract; no Kubernetes dependencies.
- `internal/server` — multiplexing, request cancellation, stream framing, shutdown, and handler boundary; no Kubernetes dependencies.
- `host/internal/kube` — replaceable adapter over Kubernetes 0.37 modules.
- `host/cmd/kubeshell-kubectl-host` — stdio/Unix-socket host executable.
- `experimental/cshared` — retained proof of the earlier C ABI direction; never loaded by the production backend.

The split is deliberate: the stable KubeShell protocol is outside the Kubernetes dependency module, while upstream kubectl/client-go churn is confined to `host/`.

## Build

Kubernetes 0.37 modules declare Go 1.26, so the host build fails closed on older toolchains.

```sh
./build.sh
```

The output is written under `bin/<rid>/kubeshell-kubectl-host`, with Go `amd64` mapped to .NET RID `x64`. PowerShell builds can use `./build.ps1`.

The helper embeds `k8s.io/kubectl`, `k8s.io/cli-runtime`, `k8s.io/client-go`, and their transitive dependencies into the executable. No external kubectl executable is used by this host.

## Transport

`--transport=stdio` is the packaged/default mode. Redirected stdin/stdout are private to the child process and work consistently on Linux, macOS, and Windows. `--transport=unix --socket <path>` exists for diagnostics/external-host experiments on Unix.

Protocol details are in `../../docs/KUBECTL-HOST-PROTOCOL.md`.
