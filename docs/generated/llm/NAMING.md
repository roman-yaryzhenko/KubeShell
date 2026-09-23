# Naming and verb semantics

KubeShell follows PowerShell's `Verb-Noun` convention for public functions and uses approved verbs. The verb is chosen for operation semantics, not only to satisfy `Get-Verb`.

| Family | KubeShell meaning |
| --- | --- |
| `Get-*` | Read resources or derived state without mutation. |
| `New-*` | Create a new named local/session resource. Existing names normally conflict unless replacement is explicit. |
| `Set-*` | Bring mutable state or properties to the requested value. Prefer idempotent behavior. |
| `Remove-*` | Remove a resource or stored object. |
| `Test-*` | Evaluate health, validity, access, or another condition without mutation. |
| `Watch-*` | Continuously observe Kubernetes resource changes and emit a stream of events. |
| `Wait-*` | Block until a requested state or rollout condition is reached. |
| `Use-*` | Make an existing KubeShell configuration/profile the current session target. |
| `Select-*` | Select an item from a collection, including interactive selection. |
| `Invoke-*` | Perform a synchronous action or execute a script block in a scoped KubeShell target. |
| `Start-*` / `Stop-*` | Start or stop a long-lived operation such as port forwarding. |
| `Enter-*` | Enter an interactive pod/node/debug context. |
| `Push-*` / `Pop-*` | Save and restore session context through a stack. |
| `Sync-*` | Request reconciliation when the external system defines reconciliation semantics, such as Flux. |
| `Suspend-*` / `Resume-*` | Change lifecycle suspension state. |

Deliberate naming decisions:

- `Watch-KubeResource` mirrors both the Kubernetes watch API and PowerShell's approved `Watch` verb.
- `Use-KubeProfile` and `Use-KubeConfigSet` change the current KubeShell session target. `Select` is reserved for choosing an object from a collection, as in `Select-KubeResource`.
- `Set-KubeConfigEnvironment` mutates `KUBECONFIG` in the current PowerShell process; `Export` would imply a data-export operation rather than an environment-state change.
- `Set-KubeManifest` is the PowerShell-facing desired-state operation corresponding to `kubectl apply`. `Apply` is not used as a public function verb.
- Terse interactive aliases (`kgp`, `kx`, `kwatch`, and similar) are allowed. Aliases that resemble full `Verb-Noun` commands are held to the approved-verb rule as well.

`Tests/VerbAudit.mjs` provides a Node-only static gate. `Tests/Runtime.ps1` repeats the check against the runtime `Get-Verb` list when PowerShell is available; the runtime result is authoritative if PowerShell adds approved verbs in a later release.
