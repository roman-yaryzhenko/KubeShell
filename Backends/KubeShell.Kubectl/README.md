# KubeShell.Kubectl

`KubeShell.Kubectl.dll` is the kubectl-semantics backend. It does **not** load Go into CoreCLR.
Instead it owns a long-lived `kubeshell-kubectl-host` child process and talks to it over a small,
versioned framed protocol.

The host embeds `k8s.io/kubectl`, `k8s.io/cli-runtime`, and `k8s.io/client-go`. This keeps upstream
Go churn out of `KubeShell.Runtime` and avoids the unsupported CoreCLR + Go-runtime in-process
combination.

The default transport is redirected stdio, which is private to the child process and works on all
supported .NET platforms. The host also exposes a Unix-domain-socket mode for diagnostics and
future external-host scenarios.

Set `KUBESHELL_KUBECTL_HOST` or `KubectlHostOptions.HostPath` to override executable discovery.
