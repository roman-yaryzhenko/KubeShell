using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlConfigService
{
    private readonly KubectlSessionPool _sessions;

    internal KubectlConfigService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async ValueTask<KubeConfigView> GetConfigViewAsync(KubeTarget target, CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        try
        {
            WireConfigViewResponse response = await session.Client.RequestAsync<object, WireConfigViewResponse>(
                WireProtocol.Method.ConfigView, session.Id, new { }, cancellationToken).ConfigureAwait(false);
            return new KubeConfigView(
                response.CurrentContext,
                (response.Contexts ?? Array.Empty<WireConfigContext>())
                    .Select(x => new KubeConfigContextInfo(x.Name, x.Cluster, x.User, x.Namespace))
                    .ToArray());
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.config.transport"); }
    }
}
