using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public enum KubeDebugContinuation
{
    None,
    Attach,
    Logs
}

/// <summary>
/// Backend-neutral description of kubectl debug semantics. The current PowerShell surface uses a
/// subset of these options, but the Runtime contract deliberately models the wider upstream debug
/// surface so adding copy-to/custom-profile/set-image workflows does not require another ABI shape.
/// Nullable booleans preserve kubectl's distinction between an omitted flag and an explicitly set
/// true/false flag where upstream behavior depends on Flag.Changed.
/// </summary>
public sealed record KubeDebugRequest(
    ResourceIdentity Target,
    string? Image = null,
    IReadOnlyList<string>? Command = null,
    bool ArgumentsOnly = false,
    bool? Attach = null,
    string? Container = null,
    string? CopyTo = null,
    bool Replace = false,
    IReadOnlyDictionary<string, string>? Environment = null,
    bool Interactive = false,
    bool Tty = false,
    bool Quiet = false,
    bool KeepLabels = false,
    bool KeepAnnotations = false,
    bool KeepLiveness = false,
    bool KeepReadiness = false,
    bool KeepStartup = false,
    bool? KeepInitContainers = null,
    bool SameNode = false,
    IReadOnlyDictionary<string, string>? SetImages = null,
    bool? ShareProcesses = null,
    string? TargetContainer = null,
    string Profile = "general",
    string? CustomProfileJson = null,
    string? ImagePullPolicy = null)
{
    public KubeDebugRequest(
        ResourceIdentity target,
        string image,
        IReadOnlyList<string>? command,
        string? targetContainer,
        string profile)
        : this(target, image, command, Attach: null, Interactive: true, Tty: true, TargetContainer: targetContainer, Profile: profile) { }

    public IReadOnlyList<string> CommandParts { get; init; } = Command ?? Array.Empty<string>();
    public IReadOnlyDictionary<string, string> EnvironmentVariables { get; init; } = Environment ?? new Dictionary<string, string>();
    public IReadOnlyDictionary<string, string> ImageOverrides { get; init; } = SetImages ?? new Dictionary<string, string>();
}

public sealed record KubeDebugAttachment(
    string Namespace,
    string Pod,
    string Container,
    KubeDebugContinuation Continuation,
    bool Interactive,
    bool Tty,
    bool Quiet = false);

public sealed record KubeDebugResult(
    KubeResource? Resource,
    KubeDebugAttachment? Attachment = null,
    IReadOnlyList<KubeWarning>? Warnings = null,
    string? Output = null)
{
    public IReadOnlyList<KubeWarning> EffectiveWarnings { get; init; } = Warnings ?? Array.Empty<KubeWarning>();
}

public interface IKubeDebugBackend
{
    ValueTask<KubeDebugResult> DebugAsync(
        KubeDebugRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

/// <summary>Routes debug mutations to a semantic backend without exposing kubectl option types.</summary>
public sealed class KubeDebugClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeDebugClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeDebugClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public KubeDebugResult Debug(
        KubeTarget target,
        KubeDebugRequest request,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(request);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        IKubeDebugBackend backend = _selector.SelectCapabilityAsync(
            new KubeDebugCapabilityRequest(request), target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
        return backend.DebugAsync(request, target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }
}
