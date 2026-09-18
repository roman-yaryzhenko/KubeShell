# KubeShell.Provider

Optional binary PowerShell provider exposing Kubernetes targets through the discovery-driven `KubeShell.ObjectModel`.

The provider is a PowerShell framework adapter, not a kubectl transport implementation. Backend selection and lifetime are owned by `KubeShell.Hosting`; navigation and CRUD use frontend-neutral Runtime/ObjectModel contracts.

```powershell
./build-with-pwsh.ps1
Import-Module ./KubeShell.Provider.psd1

# Canonical target tree: resource collections come from discovery.
cd Kube:\Namespaces\default\pods
Get-ChildItem
Get-Item .\my-pod

# Independent drives can use persisted KubeShell targets.
New-PSDrive -Name Prod -PSProvider Kube -Root 'profile:prod-payments'
New-PSDrive -Name Lab  -PSProvider Kube -Root 'configset:lab'

# Mount arbitrary subtrees directly.
New-PSDrive -Name Payments -PSProvider Kube -Root 'profile:prod' -Namespace payments
New-PSDrive -Name Deployments -PSProvider Kube -Root 'profile:prod' -Namespace payments -Resource deployments.apps
New-PSDrive -Name Pods -PSProvider Kube -Root 'profile:prod' -Resource pods -AllNamespaces
New-PSDrive -Name Nodes -PSProvider Kube -Root 'profile:prod' -Resource nodes

# Refresh ObjectModel navigation topology without forcing Runtime/backend rediscovery.
Get-ChildItem Payments:\ -Refresh

# Preview a delete. No Kubernetes mutation is sent.
Remove-Item Kube:\Namespaces\default\pods\my-pod -WhatIf

# Apply/upsert JSON to an item path.
Set-Item Kube:\Namespaces\default\configmaps\example -Value $manifest -WhatIf

# Atomic create-only by default. -Force selects Provider-level Apply/upsert semantics.
New-Item Kube:\Namespaces\default\configmaps\example -Value $manifest -WhatIf
```

`Remove-Item` on a Kubernetes Node additionally requires `-Force`. Provider `-Force` is frontend policy and is not Kubernetes server-side-apply force-conflict ownership.

Drive roots support context, profile and config-set references:

```text
<context-name>
profile:<KubeShell profile name>
configset:<KubeShell config-set name>
```

`-Namespace`, `-Resource`, and `-AllNamespaces` are New-PSDrive dynamic parameters. Namespaced resources require `-Namespace` or `-AllNamespaces`; cluster-scoped resources reject namespace scope. Resource aliases (plural, singular, Kind, short name and canonical `resource.group`) are resolved through discovery and ambiguous aliases fail explicitly.

For `-AllNamespaces`, the first level is a set of virtual namespace buckets so equal resource names in different namespaces remain unambiguous. CRDs appear automatically because the Provider has no hardcoded resource catalog.

Write payloads are JSON text or an existing KubeShell presentation object carrying `RawJson`. Runtime validates resource identity before execution. `New-Item` maps to atomic `Create`, `Set-Item` maps to `Apply`, and `Remove-Item` maps to `Delete`; warnings and diagnostics from Runtime are preserved at the PowerShell boundary.
