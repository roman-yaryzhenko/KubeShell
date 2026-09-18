using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlOperationExecutor
{
    private readonly KubectlSessionPool _sessions;

    internal KubectlOperationExecutor(KubectlSessionPool sessions)
    {
        _sessions = sessions;
    }

    internal async ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        if (operation is KubeWatchOperation)
            throw new KubeException(KubeErrorKind.Unsupported, "Watch uses IKubeWatchBackend.WatchAsync rather than ExecuteAsync.", code: "kubectl.watch-contract", target: target);
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireOperationRequest request = KubectlWireMapper.Operation(operation, executionContext);
        try
        {
            WireOperationResponse response = await session.Client.RequestAsync<WireOperationRequest, WireOperationResponse>(
                KubectlWireMapper.Method(operation), session.Id, request, cancellationToken).ConfigureAwait(false);
            return KubectlWireMapper.Result(response);
        }
        catch (OperationCanceledException ex)
        {
            throw new KubeException(KubeErrorKind.Cancelled, "kubectl-host operation was cancelled.", ex, target: target, code: "kubectl.cancelled");
        }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target, Identity(operation)); }
        catch (KubeException) { throw; }
        catch (Exception ex)
        {
            throw KubectlWireMapper.TransportException(ex, target, "kubectl-host.transport");
        }
    }

    internal async IAsyncEnumerable<KubeWatchEvent> WatchAsync(
        KubeWatchOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        KubectlSession session;
        KubectlProtocolStream<WireOperationResponse> stream;
        try
        {
            session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
            WireOperationRequest request = KubectlWireMapper.Operation(operation, executionContext);
            stream = await session.Client.StartStreamAsync<WireOperationRequest, WireOperationResponse>(
                WireProtocol.Method.WatchStart, session.Id, request, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.watch.transport"); }

        await using (stream.ConfigureAwait(false))
        {
            ulong operationId = stream.Response.OperationId;
            if (operationId == 0)
                throw new KubeException(KubeErrorKind.Transport, "kubectl-host returned no operation handle for watch.", target: target, code: "kubectl.watch.handle");

            using CancellationTokenRegistration registration = cancellationToken.Register(static state =>
            {
                var tuple = ((KubectlProtocolClient Client, ulong OperationId))state!;
                _ = tuple.Client.CancelOperationAsync(tuple.OperationId);
            }, (session.Client, operationId));

            try
            {
                await foreach (WireStreamItem item in stream.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
                {
                    if (item.Error is not null)
                    {
                        yield return new KubeWatchEvent(KubeWatchEventType.Error, Error: KubectlWireMapper.Error(item.Error), ResourceVersion: item.ResourceVersion);
                        continue;
                    }
                    KubeResource? resource = item.Resource is null ? null : Resource(item.Resource);
                    yield return new KubeWatchEvent(EventType(item.EventType), resource, ResourceVersion: item.ResourceVersion);
                }
            }
            finally
            {
                // A consumer can leave await-foreach without cancelling its token. The operation
                // handle is therefore the authoritative lifetime boundary, not ChannelReader.
                try { await session.Client.CancelOperationAsync(operationId).ConfigureAwait(false); } catch { }
            }
        }
    }

    private static KubeResource Resource(WireResourceResult item)
    {
        JsonObject document = JsonNode.Parse(item.Json.GetRawText())?.AsObject()
            ?? throw new KubeException(KubeErrorKind.Serialization, "kubectl-host returned a non-object watch resource.", code: "kubectl.watch.resource");
        return KubeResource.FromDocument(KubectlWireMapper.Gvr(item.Gvr), document);
    }

    private static KubeWatchEventType EventType(string value) => value.ToLowerInvariant() switch
    {
        "added" => KubeWatchEventType.Added,
        "modified" => KubeWatchEventType.Modified,
        "deleted" => KubeWatchEventType.Deleted,
        "bookmark" => KubeWatchEventType.Bookmark,
        "error" => KubeWatchEventType.Error,
        _ => KubeWatchEventType.Error
    };

    private static ResourceIdentity? Identity(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => x.Identity,
        KubeCreateOperation x => x.Identity,
        KubeReplaceOperation x => x.Identity,
        KubeDeleteOperation x => x.Identity,
        KubePatchOperation x => x.Identity,
        KubeApplyOperation x => x.Identity,
        KubeRolloutUndoOperation x => x.Identity,
        KubeRolloutRestartOperation x => x.Identity,
        KubeScaleOperation x => x.Identity,
        KubeSetImageOperation x => x.Identity,
        KubeRolloutStatusOperation x => x.Identity,
        _ => null
    };
}
