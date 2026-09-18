using System.Runtime.CompilerServices;
using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlLogService
{
    private readonly KubectlSessionPool _sessions;

    internal KubectlLogService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async IAsyncEnumerable<string> ReadLogsAsync(
        KubeLogRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        KubectlSession session;
        KubectlProtocolStream<WireOperationResponse> stream;
        try
        {
            session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
            long sinceSeconds = request.Since is null ? 0 : checked((long)Math.Ceiling(request.Since.Value.TotalSeconds));
            WireLogRequest wire = new(
                request.Pod, KubectlWireMapper.Scope(request.Namespace), request.Container, request.TailLines,
                sinceSeconds, request.Previous, request.Follow, request.Timestamps, request.Prefix,
                KubectlWireMapper.Execution(executionContext));
            stream = await session.Client.StartStreamAsync<WireLogRequest, WireOperationResponse>(
                WireProtocol.Method.LogsStart, session.Id, wire, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.logs.transport"); }

        await using (stream.ConfigureAwait(false))
        {
            ulong operationId = stream.Response.OperationId;
            if (operationId == 0)
                throw new KubeException(KubeErrorKind.Transport, "kubectl-host returned no operation handle for logs.", target: target, code: "kubectl.logs.handle");

            using CancellationTokenRegistration registration = cancellationToken.Register(static state =>
            {
                var tuple = ((KubectlProtocolClient Client, ulong OperationId))state!;
                _ = tuple.Client.CancelOperationAsync(tuple.OperationId);
            }, (session.Client, operationId));

            try
            {
                await foreach (WireStreamItem item in stream.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
                {
                    if (item.Error is not null) throw KubectlWireMapper.Exception(new KubectlWireException(item.Error), target);
                    if (item.Text is not null) yield return item.Text;
                }
            }
            finally
            {
                try { await session.Client.CancelOperationAsync(operationId).ConfigureAwait(false); } catch { }
            }
        }
    }
}
