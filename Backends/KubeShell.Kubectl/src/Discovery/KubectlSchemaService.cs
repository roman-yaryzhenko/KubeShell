using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlSchemaService
{
    private readonly KubectlSessionPool _sessions;

    internal KubectlSchemaService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async ValueTask<KubeSchemaDocument> GetSchemaAsync(
        KubeSchemaRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireSchemaRequest wire = new(
            KubectlWireMapper.Gvr(request.Resource),
            request.FieldPath,
            request.Recursive,
            request.MaxDepth,
            KubectlWireMapper.Execution(executionContext));
        try
        {
            WireSchemaResponse response = await session.Client.RequestAsync<WireSchemaRequest, WireSchemaResponse>(
                WireProtocol.Method.Explain, session.Id, wire, cancellationToken).ConfigureAwait(false);
            return new KubeSchemaDocument(
                KubectlWireMapper.Gvr(response.Gvr),
                response.Kind,
                response.FieldPath,
                response.Type,
                response.Format,
                response.Description,
                (response.Fields ?? Array.Empty<WireSchemaField>()).Select(Field).ToArray());
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target); }
        catch (KubeException) { throw; }
        catch (Exception ex)
        {
            throw KubectlWireMapper.TransportException(ex, target, "kubectl.schema.transport");
        }
    }

    private static KubeSchemaField Field(WireSchemaField value) => new(
        value.Name,
        value.Path,
        value.Type,
        value.Format,
        value.Description,
        value.Required,
        value.Enum ?? Array.Empty<string>(),
        (value.Children ?? Array.Empty<WireSchemaField>()).Select(Field).ToArray());
}
