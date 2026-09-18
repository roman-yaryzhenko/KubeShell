using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

/// <summary>
/// Backend-neutral capability probe base. Concrete requests are typed with the semantic backend port
/// they require so callers cannot pair an unrelated capability request and backend interface.
/// </summary>
public abstract record KubeCapabilityRequest;

public abstract record KubeCapabilityRequest<TBackend> : KubeCapabilityRequest
    where TBackend : class;

public enum KubeDiscoveryCapabilityKind
{
    PreferredResources,
    ApiVersionResources,
    ResolveResource
}

public sealed record KubeDiscoveryCapabilityRequest(
    KubeDiscoveryCapabilityKind Kind,
    bool Refresh = false,
    string? ApiVersion = null,
    GroupVersionResource? Resource = null) : KubeCapabilityRequest<IKubeDiscoveryBackend>;

public sealed record KubeConfigCapabilityRequest() : KubeCapabilityRequest<IKubeConfigBackend>;
public sealed record KubeWatchCapabilityRequest(KubeWatchOperation Operation) : KubeCapabilityRequest<IKubeWatchBackend>;
public sealed record KubeSchemaCapabilityRequest(KubeSchemaRequest Request) : KubeCapabilityRequest<IKubeSchemaBackend>;
public sealed record KubeLogCapabilityRequest(KubeLogRequest Request) : KubeCapabilityRequest<IKubeLogBackend>;
public sealed record KubeCopyCapabilityRequest(KubeCopyRequest Request) : KubeCapabilityRequest<IKubeCopyBackend>;
public sealed record KubeDebugCapabilityRequest(KubeDebugRequest Request) : KubeCapabilityRequest<IKubeDebugBackend>;
public sealed record KubeAccessReviewCapabilityRequest(KubeAccessReviewRequest Request) : KubeCapabilityRequest<IKubeAccessReviewBackend>;
public sealed record KubePodMetricsCapabilityRequest(string? Namespace) : KubeCapabilityRequest<IKubePodMetricsBackend>;
public sealed record KubeNodeMetricsCapabilityRequest() : KubeCapabilityRequest<IKubeNodeMetricsBackend>;
public sealed record KubeDnsProbeCapabilityRequest(KubeDnsProbeRequest Request) : KubeCapabilityRequest<IKubeDnsProbeBackend>;

/// <summary>
/// Optional companion contract for specialized semantic interfaces. A backend implementing a specialized
/// interface must explicitly prove support for the concrete request before the selector executes it.
/// </summary>
public interface IKubeCapabilityEvaluator
{
    ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(
        KubeCapabilityRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Backend-neutral selection port. Runtime facades depend on this abstraction rather than constructing
/// or inspecting backend collections. Composition roots inject it into semantic clients; outer consumers
/// such as a future Provider should normally depend on those narrower clients rather than routing infrastructure.
/// </summary>
public interface IKubeBackendSelector
{
    ValueTask<KubeOperationSupport> EvaluateOperationAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);

    ValueTask<IKubeBackend> SelectOperationAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);

    ValueTask<TBackend> SelectCapabilityAsync<TBackend>(
        KubeCapabilityRequest<TBackend> request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
        where TBackend : class;
}

/// <summary>
/// Single ordered routing policy shared by generic operations and specialized semantic clients.
/// Ordering expresses preference only. Unknown is fail-safe: it is never executable, but a later backend
/// may still be selected if that backend explicitly reports Supported. Execution failures are never retried
/// through a different backend; routing finishes before execution starts.
/// </summary>
public sealed class KubeBackendRouter : IKubeBackendSelector
{
    private readonly IKubeBackend[] _backends;

    public KubeBackendRouter(IEnumerable<IKubeBackend> backends)
    {
        _backends = (backends ?? throw new ArgumentNullException(nameof(backends)))
            .Where(x => x is not null)
            .ToArray();
        if (_backends.Length == 0)
            throw new ArgumentException("At least one Kubernetes backend is required.", nameof(backends));
    }

    internal IReadOnlyList<IKubeBackend> Backends => _backends;

    public async ValueTask<KubeOperationSupport> EvaluateOperationAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        KubeOperationSupport? bestFailure = null;
        foreach (IKubeBackend backend in _backends)
        {
            KubeOperationSupport support = await backend
                .EvaluateAsync(operation, target, executionContext, cancellationToken)
                .ConfigureAwait(false);
            if (support.State == KubeSupportState.Supported)
                return support;
            bestFailure = PreferFailure(bestFailure, support);
        }

        return bestFailure ?? KubeOperationSupport.Unsupported(
            "routing.operation.unavailable",
            "No configured backend supports the requested Kubernetes operation.");
    }

    public async ValueTask<IKubeBackend> SelectOperationAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        KubeOperationSupport? bestFailure = null;
        foreach (IKubeBackend backend in _backends)
        {
            KubeOperationSupport support = await backend
                .EvaluateAsync(operation, target, executionContext, cancellationToken)
                .ConfigureAwait(false);
            if (support.State == KubeSupportState.Supported)
                return backend;
            bestFailure = PreferFailure(bestFailure, support);
        }

        throw RoutingFailure(
            bestFailure,
            target,
            "routing.operation.unavailable",
            "No configured backend supports the requested Kubernetes operation.");
    }

    public async ValueTask<TBackend> SelectCapabilityAsync<TBackend>(
        KubeCapabilityRequest<TBackend> request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
        where TBackend : class
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        KubeOperationSupport? bestFailure = null;
        bool semanticInterfaceSeen = false;

        foreach (IKubeBackend backend in _backends)
        {
            if (backend is not TBackend semanticBackend)
                continue;

            semanticInterfaceSeen = true;
            KubeOperationSupport support;
            if (backend is IKubeCapabilityEvaluator evaluator)
            {
                support = await evaluator
                    .EvaluateCapabilityAsync(request, target, executionContext, cancellationToken)
                    .ConfigureAwait(false);
            }
            else
            {
                // Interface presence alone is intentionally insufficient: this is the exact failure mode
                // that previously made specialized clients pick the first implementation silently.
                support = KubeOperationSupport.Unknown(
                    "routing.capability.unevaluated",
                    $"Backend '{backend.Id}' implements {typeof(TBackend).Name} but exposes no capability evaluator.");
            }

            if (support.State == KubeSupportState.Supported)
                return semanticBackend;
            bestFailure = PreferFailure(bestFailure, support);
        }

        string code = semanticInterfaceSeen ? "routing.capability.unsupported" : "routing.capability.unavailable";
        string reason = semanticInterfaceSeen
            ? $"No configured {typeof(TBackend).Name} backend explicitly supports the requested semantic capability."
            : $"No configured backend implements {typeof(TBackend).Name}.";
        throw RoutingFailure(bestFailure, target, code, reason);
    }

    private static KubeOperationSupport PreferFailure(KubeOperationSupport? current, KubeOperationSupport candidate)
    {
        if (current is null) return candidate;
        return FailureRank(candidate.State) > FailureRank(current.State) ? candidate : current;
    }

    private static int FailureRank(KubeSupportState state) => state switch
    {
        // Unknown means the router could not prove whether a backend can execute the request.
        // If no later backend is explicitly Supported, that uncertainty must survive as
        // Indeterminate rather than being hidden by a definite Unavailable/Unsupported result.
        KubeSupportState.Unknown => 3,
        KubeSupportState.Unavailable => 2,
        KubeSupportState.Unsupported => 1,
        _ => 0
    };

    private static KubeException RoutingFailure(
        KubeOperationSupport? support,
        KubeTarget target,
        string fallbackCode,
        string fallbackReason)
    {
        KubeOperationSupport effective = support ?? KubeOperationSupport.Unsupported(fallbackCode, fallbackReason);
        KubeErrorKind kind = effective.ToFailureKind();
        return new KubeException(
            kind,
            effective.Reason ?? fallbackReason,
            code: effective.ReasonCode ?? fallbackCode,
            target: target);
    }
}
