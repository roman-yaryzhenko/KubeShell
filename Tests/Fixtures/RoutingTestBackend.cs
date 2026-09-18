using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json.Nodes;
using KubeShell.Runtime;

namespace KubeShell.Tests;

public sealed class RoutingTestBackend :
    IKubeBackend,
    IKubeCapabilityEvaluator,
    IKubeDiscoveryBackend,
    IKubeWatchBackend,
    IKubeSchemaBackend,
    IKubeConfigBackend,
    IKubeAccessReviewBackend,
    IKubePodMetricsBackend,
    IKubeNodeMetricsBackend,
    IKubeDnsProbeBackend,
    IKubeLogBackend,
    IKubeCopyBackend,
    IKubeDebugBackend
{
    public RoutingTestBackend(string id, KubeSupportState operationState, KubeSupportState capabilityState, bool throwOnExecute = false)
    {
        Id = id;
        OperationState = operationState;
        CapabilityState = capabilityState;
        ThrowOnExecute = throwOnExecute;
    }

    public string Id { get; }
    public KubeSupportState OperationState { get; set; }
    public KubeSupportState CapabilityState { get; set; }
    public bool ThrowOnExecute { get; set; }
    public int EvaluateCount { get; private set; }
    public int CapabilityEvaluateCount { get; private set; }
    public int ExecuteCount { get; private set; }
    public KubeOperation? LastOperation { get; private set; }

    public ValueTask<KubeOperationSupport> EvaluateAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        EvaluateCount++;
        return ValueTask.FromResult(Support(OperationState, $"{Id}.operation"));
    }

    public ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(KubeCapabilityRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        CapabilityEvaluateCount++;
        return ValueTask.FromResult(Support(CapabilityState, $"{Id}.capability"));
    }

    public ValueTask<KubeOperationResult> ExecuteAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        ExecuteCount++;
        LastOperation = operation;
        if (ThrowOnExecute)
            throw new KubeException(KubeErrorKind.Transport, $"{Id} execution failed after selection.", code: $"{Id}.failed", target: target);
        if (operation is KubeCreateOperation create)
        {
            JsonObject document = JsonNode.Parse(create.PayloadJson)?.AsObject()
                ?? throw new InvalidOperationException("Create fixture payload must be a JSON object.");
            return ValueTask.FromResult(new KubeOperationResult(new[] { KubeResource.FromDocument(create.Identity.Gvr, document) }));
        }
        if (operation is KubeReplaceOperation replace)
        {
            JsonObject document = JsonNode.Parse(replace.PayloadJson)?.AsObject()
                ?? throw new InvalidOperationException("Replace fixture payload must be a JSON object.");
            return ValueTask.FromResult(new KubeOperationResult(new[] { KubeResource.FromDocument(replace.Identity.Gvr, document) }));
        }
        return ValueTask.FromResult(new KubeOperationResult());
    }

    private static KubeOperationSupport Support(KubeSupportState state, string code) => state switch
    {
        KubeSupportState.Supported => KubeOperationSupport.Supported(code, code),
        KubeSupportState.Unsupported => KubeOperationSupport.Unsupported(code, code),
        KubeSupportState.Unavailable => KubeOperationSupport.Unavailable(code, code),
        _ => KubeOperationSupport.Unknown(code, code)
    };

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(string apiVersion, KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(GroupVersionResource resource, KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public IAsyncEnumerable<KubeWatchEvent> WatchAsync(KubeWatchOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeSchemaDocument> GetSchemaAsync(KubeSchemaRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeConfigView> GetConfigViewAsync(KubeTarget target, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeAccessReviewResult> ReviewAccessAsync(KubeAccessReviewRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<string> GetPodMetricsJsonAsync(string? @namespace, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<string> GetNodeMetricsJsonAsync(KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeDnsProbeResult> ProbeDnsAsync(KubeDnsProbeRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public IAsyncEnumerable<string> ReadLogsAsync(KubeLogRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeCopyResult> CopyAsync(KubeCopyRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeDebugResult> DebugAsync(KubeDebugRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) => throw new NotSupportedException();
}
