using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public enum KubeSupportState
{
    Supported,
    Unsupported,
    Unavailable,
    Unknown
}

public sealed record KubeOperationSupport(KubeSupportState State, string? ReasonCode = null, string? Reason = null)
{
    public static KubeOperationSupport Supported(string? reasonCode = null, string? reason = null) => new(KubeSupportState.Supported, reasonCode, reason);
    public static KubeOperationSupport Unsupported(string code, string reason) => new(KubeSupportState.Unsupported, code, reason);
    public static KubeOperationSupport Unavailable(string code, string reason) => new(KubeSupportState.Unavailable, code, reason);
    public static KubeOperationSupport Unknown(string code, string reason) => new(KubeSupportState.Unknown, code, reason);

    /// <summary>
    /// Converts a non-supported capability decision into the stable Runtime error taxonomy.
    /// Unknown means support could not be proved and is therefore Indeterminate, not Unsupported.
    /// </summary>
    public KubeErrorKind ToFailureKind() => State switch
    {
        KubeSupportState.Unsupported => KubeErrorKind.Unsupported,
        KubeSupportState.Unavailable => KubeErrorKind.Unavailable,
        KubeSupportState.Unknown => KubeErrorKind.Indeterminate,
        _ => throw new InvalidOperationException("Supported capability decisions do not represent failures.")
    };
}

public enum KubeDiagnosticLevel
{
    Trace,
    Info,
    Warning
}

public sealed record KubeWarning(string Message, string? Code = null, string? Agent = null);
public sealed record KubeDiagnostic(string Code, string Message, KubeDiagnosticLevel Level = KubeDiagnosticLevel.Info);

public sealed class KubeOperationResult
{
    public KubeOperationResult(
        IEnumerable<KubeResource>? resources = null,
        IEnumerable<KubeWarning>? warnings = null,
        IEnumerable<KubeDiagnostic>? diagnostics = null)
    {
        Resources = (resources ?? Array.Empty<KubeResource>()).ToArray();
        Warnings = (warnings ?? Array.Empty<KubeWarning>()).ToArray();
        Diagnostics = (diagnostics ?? Array.Empty<KubeDiagnostic>()).ToArray();
    }

    public IReadOnlyList<KubeResource> Resources { get; }
    public IReadOnlyList<KubeWarning> Warnings { get; }
    public IReadOnlyList<KubeDiagnostic> Diagnostics { get; }
    public KubeResource? Resource => Resources.Count == 0 ? null : Resources[0];
}

public interface IKubeBackend
{
    string Id { get; }

    ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);

    ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public interface IKubeDiscoveryBackend
{
    ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        GroupVersionResource resource,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default);
}

public interface IKubeWatchBackend
{
    IAsyncEnumerable<KubeWatchEvent> WatchAsync(
        KubeWatchOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}
