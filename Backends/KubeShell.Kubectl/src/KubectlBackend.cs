using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

/// <summary>
/// kubectl-faithful backend implemented by a long-lived Go helper process. The public adapter owns
/// only Runtime routing; process lifecycle, sessions, discovery, protocol and execution remain isolated.
/// </summary>
public sealed class KubectlBackend : IKubeBackend, IKubeDiscoveryBackend, IKubeWatchBackend, IKubeSchemaBackend, IKubeConfigBackend, IKubeAccessReviewBackend, IKubePodMetricsBackend, IKubeNodeMetricsBackend, IKubeDnsProbeBackend, IKubeLogBackend, IKubeCopyBackend, IKubeDebugBackend, IKubeCapabilityEvaluator, IAsyncDisposable
{
    private readonly KubectlHostProcess _host;
    private readonly KubectlDiscoveryService _discovery;
    private readonly KubectlSupportEvaluator _support;
    private readonly KubectlOperationExecutor _executor;
    private readonly KubectlSchemaService _schema;
    private readonly KubectlConfigService _config;
    private readonly KubectlDiagnosticsService _diagnostics;
    private readonly KubectlLogService _logs;
    private readonly KubectlCopyService _copy;
    private readonly KubectlDebugService _debug;

    public KubectlBackend() : this(null) { }

    public KubectlBackend(KubectlHostOptions? options)
    {
        _host = new KubectlHostProcess(options);
        KubectlSessionPool sessions = new(_host);
        _discovery = new KubectlDiscoveryService(sessions);
        _support = new KubectlSupportEvaluator(_host, _discovery);
        _executor = new KubectlOperationExecutor(sessions);
        _schema = new KubectlSchemaService(sessions);
        _config = new KubectlConfigService(sessions);
        _diagnostics = new KubectlDiagnosticsService(sessions);
        _logs = new KubectlLogService(sessions);
        _copy = new KubectlCopyService(sessions);
        _debug = new KubectlDebugService(sessions);
    }

    public string Id => "kubectl";

    public ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default) =>
        _support.EvaluateAsync(operation, target, executionContext, cancellationToken);

    public ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(
        KubeCapabilityRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default) =>
        _support.EvaluateCapabilityAsync(request, target, executionContext, cancellationToken);

    public async ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        KubeOperationSupport support = await EvaluateAsync(operation, target, executionContext, cancellationToken).ConfigureAwait(false);
        if (support.State != KubeSupportState.Supported)
        {
            KubeErrorKind kind = support.ToFailureKind();
            throw new KubeException(kind, support.Reason ?? "kubectl backend cannot prove support for this operation.", target: target, code: support.ReasonCode);
        }
        return await _executor.ExecuteAsync(operation, target, executionContext, cancellationToken).ConfigureAwait(false);
    }

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        _discovery.GetPreferredResourcesAsync(target, executionContext, refresh, cancellationToken);

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        _discovery.GetApiVersionResourcesAsync(apiVersion, target, executionContext, refresh, cancellationToken);

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        GroupVersionResource resource,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        _discovery.ResolveResourceAsync(resource, target, executionContext, refresh, cancellationToken);

    public IAsyncEnumerable<KubeWatchEvent> WatchAsync(
        KubeWatchOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default) =>
        _executor.WatchAsync(operation, target, executionContext, cancellationToken);


    public ValueTask<KubeSchemaDocument> GetSchemaAsync(
        KubeSchemaRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default) =>
        _schema.GetSchemaAsync(request, target, executionContext, cancellationToken);

    public ValueTask<KubeConfigView> GetConfigViewAsync(
        KubeTarget target,
        CancellationToken cancellationToken = default) =>
        _config.GetConfigViewAsync(target, cancellationToken);


    public ValueTask<KubeAccessReviewResult> ReviewAccessAsync(
        KubeAccessReviewRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _diagnostics.ReviewAccessAsync(request, target, executionContext, cancellationToken);

    public ValueTask<string> GetPodMetricsJsonAsync(
        string? @namespace, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _diagnostics.GetPodMetricsJsonAsync(@namespace, target, executionContext, cancellationToken);

    public ValueTask<string> GetNodeMetricsJsonAsync(
        KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _diagnostics.GetNodeMetricsJsonAsync(target, executionContext, cancellationToken);

    public ValueTask<KubeDnsProbeResult> ProbeDnsAsync(
        KubeDnsProbeRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _diagnostics.ProbeDnsAsync(request, target, executionContext, cancellationToken);


    public IAsyncEnumerable<string> ReadLogsAsync(
        KubeLogRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _logs.ReadLogsAsync(request, target, executionContext, cancellationToken);


    public ValueTask<KubeCopyResult> CopyAsync(
        KubeCopyRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _copy.CopyAsync(request, target, executionContext, cancellationToken);

    public ValueTask<KubeDebugResult> DebugAsync(
        KubeDebugRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        _debug.DebugAsync(request, target, executionContext, cancellationToken);

    public ValueTask DisposeAsync() => _host.DisposeAsync();
}
