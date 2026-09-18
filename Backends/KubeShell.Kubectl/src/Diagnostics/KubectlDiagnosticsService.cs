using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlDiagnosticsService
{
    private readonly KubectlSessionPool _sessions;

    internal KubectlDiagnosticsService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async ValueTask<KubeAccessReviewResult> ReviewAccessAsync(
        KubeAccessReviewRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireAccessReviewRequest wire = new(
            request.Verb, request.Resource, request.Name, request.Namespace, request.Group, request.Subresource, request.Namespaced,
            request.AsUser, request.Groups.ToArray(), KubectlWireMapper.Execution(executionContext));
        try
        {
            WireAccessReviewResponse response = await session.Client.RequestAsync<WireAccessReviewRequest, WireAccessReviewResponse>(
                WireProtocol.Method.AccessReview, session.Id, wire, cancellationToken).ConfigureAwait(false);
            return new KubeAccessReviewResult(response.Allowed, response.Denied, response.Reason, response.EvaluationError);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.diagnostics.access.transport"); }
    }

    internal async ValueTask<string> GetPodMetricsJsonAsync(
        string? @namespace,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        WireMetricsResponse response = await MetricsAsync(WireProtocol.Method.PodMetrics, @namespace, target, executionContext, cancellationToken).ConfigureAwait(false);
        return response.Json;
    }

    internal async ValueTask<string> GetNodeMetricsJsonAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        WireMetricsResponse response = await MetricsAsync(WireProtocol.Method.NodeMetrics, null, target, executionContext, cancellationToken).ConfigureAwait(false);
        return response.Json;
    }

    private async ValueTask<WireMetricsResponse> MetricsAsync(
        WireProtocol.Method method,
        string? @namespace,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireMetricsRequest request = new(@namespace, KubectlWireMapper.Execution(executionContext));
        try
        {
            return await session.Client.RequestAsync<WireMetricsRequest, WireMetricsResponse>(method, session.Id, request, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.diagnostics.metrics.transport"); }
    }

    internal async ValueTask<KubeDnsProbeResult> ProbeDnsAsync(
        KubeDnsProbeRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireDnsProbeRequest wire = new(
            request.Namespace, request.Name, request.Image, checked((long)request.Timeout.TotalMilliseconds),
            KubectlWireMapper.Execution(executionContext));
        try
        {
            WireDnsProbeResponse response = await session.Client.RequestAsync<WireDnsProbeRequest, WireDnsProbeResponse>(
                WireProtocol.Method.DnsProbe, session.Id, wire, cancellationToken).ConfigureAwait(false);
            return new KubeDnsProbeResult(response.Success, response.Output);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.diagnostics.dns.transport"); }
    }
}
