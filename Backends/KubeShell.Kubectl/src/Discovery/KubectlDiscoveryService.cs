using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlDiscoveryService
{
    private readonly KubectlSessionPool _sessions;

    internal KubectlDiscoveryService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireDiscoverRequest request = new(null, null, refresh, KubectlWireMapper.Execution(executionContext));
        try
        {
            WireDiscoverResponse response = await session.Client.RequestAsync<WireDiscoverRequest, WireDiscoverResponse>(
                WireProtocol.Method.DiscoverPreferred, session.Id, request, cancellationToken).ConfigureAwait(false);
            return (response.Resources ?? Array.Empty<WireResourceDescriptor>()).Select(KubectlWireMapper.Descriptor).ToArray();
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex)
        {
            throw KubectlWireMapper.TransportException(ex, target, "kubectl.discovery.transport");
        }
    }

    internal async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireDiscoverRequest request = new(apiVersion, null, refresh, KubectlWireMapper.Execution(executionContext));
        try
        {
            WireDiscoverResponse response = await session.Client.RequestAsync<WireDiscoverRequest, WireDiscoverResponse>(
                WireProtocol.Method.DiscoverApiVersion, session.Id, request, cancellationToken).ConfigureAwait(false);
            return (response.Resources ?? Array.Empty<WireResourceDescriptor>()).Select(KubectlWireMapper.Descriptor).ToArray();
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex)
        {
            throw KubectlWireMapper.TransportException(ex, target, "kubectl.discovery.transport");
        }
    }

    internal async ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        GroupVersionResource resource,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireDiscoverRequest request = new(null, KubectlWireMapper.Gvr(resource), refresh, KubectlWireMapper.Execution(executionContext));
        try
        {
            WireDiscoverResponse response = await session.Client.RequestAsync<WireDiscoverRequest, WireDiscoverResponse>(
                WireProtocol.Method.ResolveResource, session.Id, request, cancellationToken).ConfigureAwait(false);
            WireResourceDescriptor? descriptor = response.Resources?.FirstOrDefault();
            return descriptor is null ? null : KubectlWireMapper.Descriptor(descriptor);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) when (string.Equals(ex.Error.Code, "kubectl.discovery.no-match", StringComparison.Ordinal)) { return null; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex)
        {
            throw KubectlWireMapper.TransportException(ex, target, "kubectl.discovery.transport");
        }
    }
}
