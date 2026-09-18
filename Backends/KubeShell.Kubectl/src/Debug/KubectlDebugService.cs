using System.Text.Json.Nodes;
using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlDebugService
{
    private readonly KubectlSessionPool _sessions;
    internal KubectlDebugService(KubectlSessionPool sessions) => _sessions = sessions;

    internal async ValueTask<KubeDebugResult> DebugAsync(
        KubeDebugRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubectlSession session = await _sessions.GetAsync(target, cancellationToken).ConfigureAwait(false);
        WireDebugRequest wire = new(
            KubectlWireMapper.Resource(request.Target),
            request.Image,
            request.CommandParts.ToArray(),
            request.ArgumentsOnly,
            request.Attach,
            request.Container,
            request.CopyTo,
            request.Replace,
            request.EnvironmentVariables.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal),
            request.Interactive,
            request.Tty,
            request.Quiet,
            request.KeepLabels,
            request.KeepAnnotations,
            request.KeepLiveness,
            request.KeepReadiness,
            request.KeepStartup,
            request.KeepInitContainers,
            request.SameNode,
            request.ImageOverrides.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal),
            request.ShareProcesses,
            request.TargetContainer,
            request.Profile,
            request.CustomProfileJson,
            request.ImagePullPolicy,
            KubectlWireMapper.Execution(executionContext));
        try
        {
            WireDebugResponse response = await session.Client.RequestAsync<WireDebugRequest, WireDebugResponse>(
                WireProtocol.Method.Debug, session.Id, wire, cancellationToken).ConfigureAwait(false);
            KubeResource? resource = response.Resource is null ? null : ToResource(response.Resource);
            KubeDebugAttachment? attachment = response.Attachment is null ? null : new KubeDebugAttachment(
                response.Attachment.Namespace,
                response.Attachment.Pod,
                response.Attachment.Container,
                ParseContinuation(response.Attachment.Continuation),
                response.Attachment.Interactive,
                response.Attachment.Tty,
                response.Attachment.Quiet);
            KubeWarning[] warnings = (response.Warnings ?? Array.Empty<string>())
                .Select(message => new KubeWarning(message, "kubectl-host.debug", "kubectl"))
                .ToArray();
            return new KubeDebugResult(resource, attachment, warnings, response.Output);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubectlWireException ex) { throw KubectlWireMapper.Exception(ex, target, request.Target); }
        catch (KubeException) { throw; }
        catch (Exception ex) { throw KubectlWireMapper.TransportException(ex, target, "kubectl.debug.transport"); }
    }

    private static KubeResource ToResource(WireResourceResult item)
    {
        JsonObject document = JsonNode.Parse(item.Json.GetRawText())?.AsObject()
            ?? throw new KubeException(KubeErrorKind.Serialization, "kubectl-host returned a non-object debug resource.", code: "kubectl.debug.resource");
        return KubeResource.FromDocument(KubectlWireMapper.Gvr(item.Gvr), document);
    }

    private static KubeDebugContinuation ParseContinuation(string? value) => value?.ToLowerInvariant() switch
    {
        "attach" => KubeDebugContinuation.Attach,
        "logs" => KubeDebugContinuation.Logs,
        _ => KubeDebugContinuation.None
    };
}
