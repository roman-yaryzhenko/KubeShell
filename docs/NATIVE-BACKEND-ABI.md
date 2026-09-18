# Historical C ABI design (superseded for production)

This document records the earlier `Go c-shared + P/Invoke` direction. It is retained because the ABI exercise produced useful ownership/session/cancellation boundaries, and the architecture introduced in `0.3.0-alpha10.9-ipc`, retained in `0.3.0-alpha11`, **does not load Go into CoreCLR**.

The production boundary is documented in [`KUBECTL-HOST-PROTOCOL.md`](KUBECTL-HOST-PROTOCOL.md). The original C ABI proof remains under `native/kubeshell-kubectl/experimental/cshared` only.

## Why it was superseded

Go supports `-buildmode=c-shared` and .NET supports C P/Invoke individually, but .NET's native-interop guidance does not treat Go as a supported in-process interoperability runtime. More importantly for KubeShell, a helper process gives deterministic crash isolation, cancellation of wedged streams, independent Go-runtime lifecycle, easier upgrades/debugging, and negligible practical overhead relative to Kubernetes API round trips.

The earlier design principles were preserved in the wire protocol:

- a small KubeShell-owned stable boundary;
- numeric operation/method IDs independent of kubectl internal types;
- explicit session and operation handles;
- structured errors rather than process exit codes;
- Kubernetes objects represented as UTF-8 JSON;
- fail-closed semantic negotiation;
- no silent Client->Server preview or CSA->SSA substitution;
- long-lived operations separated from ordinary request lifetime.

There is therefore no production memory-ownership contract such as `ks_buffer`/`ks_free`, no `NativeLibrary.Load`, and no exported Go pointers. Process-local Go memory never crosses the IPC boundary.
