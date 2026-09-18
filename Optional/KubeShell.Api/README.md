# KubeShell.Api

Experimental PowerShell frontend for `Backends/KubeShell.KubernetesClient`, the managed adapter over the official Kubernetes C# client (`KubernetesClient` 19.0.2).

The module owns PowerShell session/bootstrap and `ShouldProcess`. Kubernetes CRUD, server dry-run and server-side API semantics are expressed through `KubeShell.Runtime` operations and executed by the managed backend. Runtime itself does not reference the official SDK.

Build the backend first with the .NET 8 SDK:

```powershell
../../Backends/KubeShell.KubernetesClient/build.ps1
Import-Module ./KubeShell.Api.psd1
```

`New-KubeApiSession -FromKubectlContext` delegates kubeconfig parsing, TLS and exec credential plugins to the official client. Explicit server/token/certificate sessions are also supported.

Discovery is cached separately from resource data. `Get-KubeApiDiscovery -Refresh` invalidates/refetches the API-version discovery projection.

Client preview and client-side apply are intentionally not implemented here; they belong to the future optional kubectl/client-go backend.
