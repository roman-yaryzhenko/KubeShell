using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlCopyService
{
    private readonly KubectlSessionPool _sessions;
    internal KubectlCopyService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async ValueTask<KubeCopyResult> CopyAsync(
        KubeCopyRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireCopyRequest wire = new(
            request.Pod, KubectlWireMapper.Scope(request.Namespace), request.LocalPath, request.RemotePath,
            request.ToPod, request.Container, KubectlWireMapper.Execution(executionContext));
        try
        {
            WireCopyResponse response = await session.Client.RequestAsync<WireCopyRequest, WireCopyResponse>(
                WireProtocol.Method.Copy, session.Id, wire, cancellationToken).ConfigureAwait(false);
            return new KubeCopyResult(response.Output, response.ErrorOutput);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.copy.transport"); }
    }
}
