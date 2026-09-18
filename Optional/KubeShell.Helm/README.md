# KubeShell.Helm

Optional Helm CLI integration. Requires `helm` in `PATH`. Helm child processes inherit the selected KubeShell ConfigSet/Profile through child-only `KUBECONFIG`, `--kube-context`, and namespace defaults without changing the parent PowerShell environment.

```powershell
Import-Module ./Optional/KubeShell.Helm/KubeShell.Helm.psd1

Get-KubeHelmRelease -AllNamespaces
Get-KubeHelmRelease app -Namespace default | Get-KubeHelmHistory
Get-KubeHelmValue app -Namespace default -All
```
