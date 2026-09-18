using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public sealed record KubeAccessReviewRequest(
    string Verb,
    string Resource,
    string? Name = null,
    string? Namespace = null,
    string? Group = null,
    string? Subresource = null,
    bool Namespaced = false,
    string? AsUser = null,
    IReadOnlyList<string>? AsGroups = null)
{
    public IReadOnlyList<string> Groups { get; init; } = AsGroups ?? Array.Empty<string>();
}

public sealed record KubeAccessReviewResult(bool Allowed, bool Denied, string? Reason = null, string? EvaluationError = null);
public sealed record KubeDnsProbeRequest(string Namespace, string Name, string Image, TimeSpan Timeout);
public sealed record KubeDnsProbeResult(bool Success, string Output);

public interface IKubeAccessReviewBackend
{
    ValueTask<KubeAccessReviewResult> ReviewAccessAsync(
        KubeAccessReviewRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public interface IKubePodMetricsBackend
{
    ValueTask<string> GetPodMetricsJsonAsync(
        string? @namespace,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public interface IKubeNodeMetricsBackend
{
    ValueTask<string> GetNodeMetricsJsonAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public interface IKubeDnsProbeBackend
{
    ValueTask<KubeDnsProbeResult> ProbeDnsAsync(
        KubeDnsProbeRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

/// <summary>Routes diagnostics through narrow capability ports without exposing generated client or transport types.</summary>
public sealed class KubeDiagnosticsClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeDiagnosticsClient(IKubeBackendSelector selector) =>
        _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeDiagnosticsClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public KubeAccessReviewResult ReviewAccess(
        KubeTarget target,
        KubeAccessReviewRequest request,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(request);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        KubeAccessReviewCapabilityRequest capability = new(request);
        IKubeAccessReviewBackend backend = _selector.SelectCapabilityAsync(capability, target, context, cancellationToken)
            .AsTask().GetAwaiter().GetResult();
        return backend.ReviewAccessAsync(request, target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }

    public string GetPodMetricsJson(
        KubeTarget target,
        string? @namespace = null,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        KubePodMetricsCapabilityRequest capability = new(@namespace);
        IKubePodMetricsBackend backend = _selector.SelectCapabilityAsync(capability, target, context, cancellationToken)
            .AsTask().GetAwaiter().GetResult();
        return backend.GetPodMetricsJsonAsync(@namespace, target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }

    public string GetNodeMetricsJson(
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        KubeNodeMetricsCapabilityRequest capability = new();
        IKubeNodeMetricsBackend backend = _selector.SelectCapabilityAsync(capability, target, context, cancellationToken)
            .AsTask().GetAwaiter().GetResult();
        return backend.GetNodeMetricsJsonAsync(target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }

    public KubeDnsProbeResult ProbeDns(
        KubeTarget target,
        KubeDnsProbeRequest request,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(request);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        KubeDnsProbeCapabilityRequest capability = new(request);
        IKubeDnsProbeBackend backend = _selector.SelectCapabilityAsync(capability, target, context, cancellationToken)
            .AsTask().GetAwaiter().GetResult();
        return backend.ProbeDnsAsync(request, target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }
}
