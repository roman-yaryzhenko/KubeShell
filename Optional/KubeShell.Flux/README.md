# KubeShell.Flux

Optional Flux CRD integration for KubeShell. It uses Kubernetes CRDs directly and does not require the `flux` CLI.

```powershell
Import-Module ./Optional/KubeShell.Flux/KubeShell.Flux.psd1

Get-KubeFluxKustomization -AllNamespaces
Get-KubeFluxKustomization app -Namespace flux-system | Sync-KubeFluxKustomization
Get-KubeFluxHelmRelease app -Namespace flux-system | Suspend-KubeFluxHelmRelease -WhatIf
```

Reconciliation is requested with `reconcile.fluxcd.io/requestedAt`; suspend/resume patches `.spec.suspend`.
