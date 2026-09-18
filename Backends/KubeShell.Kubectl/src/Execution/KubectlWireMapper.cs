using System.Text.Json;
using System.Text.Json.Nodes;
using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal static class KubectlWireMapper
{
    internal static WireExecutionContext Execution(KubeExecutionContext context)
    {
        WireImpersonation? impersonation = context.Impersonation is null ? null : new WireImpersonation(
            context.Impersonation.User,
            context.Impersonation.Uid,
            context.Impersonation.EffectiveGroups.ToArray(),
            context.Impersonation.EffectiveExtra.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray(), StringComparer.Ordinal));
        return new WireExecutionContext(
            context.Timeout is null ? 0 : checked((long)context.Timeout.Value.TotalMilliseconds),
            context.UserAgent,
            context.FieldValidation.ToString(),
            context.CorrelationId,
            impersonation);
    }

    internal static WireGvr Gvr(GroupVersionResource value) => new(value.Group, value.Version, value.Resource);

    internal static GroupVersionResource Gvr(WireGvr value) => new(value.Group ?? string.Empty, value.Version ?? string.Empty, value.Resource);

    internal static WireNamespaceScope Scope(KubeNamespaceScope scope) => scope.Kind switch
    {
        KubeNamespaceScopeKind.Explicit => new("explicit", scope.Name),
        KubeNamespaceScopeKind.All => new("all"),
        KubeNamespaceScopeKind.Cluster => new("cluster"),
        _ => new("default")
    };

    internal static WireResourceRef Resource(ResourceIdentity identity) => new(Gvr(identity.Gvr), identity.Name, Scope(identity.NamespaceScope), identity.Subresource);
    internal static WireQuery Query(ResourceQuery query) => new(Gvr(query.Gvr), query.Name, Scope(query.NamespaceScope), query.LabelSelector, query.FieldSelector, query.Subresource);

    internal static WireOperationRequest Operation(KubeOperation operation, KubeExecutionContext context) => operation switch
    {
        KubeGetOperation x => new(Resource(x.Identity), null, Execution(context)),
        KubeListOperation x => new(null, Query(x.Query), Execution(context)),
        KubeCreateOperation x => new(Resource(x.Identity), null, Execution(context), Payload(x.PayloadJson), Preview: x.Options.Preview.ToString(), FieldManager: x.Options.FieldManager),
        KubeReplaceOperation x => new(Resource(x.Identity), null, Execution(context), Payload(x.PayloadJson), Preview: x.Options.Preview.ToString(), FieldManager: x.Options.FieldManager, Concurrency: Concurrency(x.Options.Concurrency)),
        KubeApplyOperation x => new(Resource(x.Identity), null, Execution(context), Payload(x.PayloadJson), Preview: x.Options.Preview.ToString(), ApplyStrategy: x.Options.Strategy.ToString(), FieldManager: x.Options.FieldManager, ForceConflicts: x.Options.ForceConflicts),
        KubePatchOperation x => new(Resource(x.Identity), null, Execution(context), Payload(x.PayloadJson), Preview: x.Options.Preview.ToString(), PatchType: x.Options.Type.ToString(), FieldManager: x.Options.FieldManager, Concurrency: Concurrency(x.Options.Concurrency)),
        KubeDeleteOperation x => new(Resource(x.Identity), null, Execution(context), Preview: x.Options.Preview.ToString(), Force: x.Options.Force, GracePeriodSeconds: x.Options.GracePeriodSeconds is int grace ? (long?)grace : null, Concurrency: Concurrency(x.Options.Concurrency)),
        KubeWatchOperation x => new(null, Query(x.Query), Execution(context), ResourceVersion: x.ResourceVersion, AllowBookmarks: x.AllowBookmarks),
        KubeRolloutUndoOperation x => new(Resource(x.Identity), null, Execution(context), Preview: x.Preview.ToString(), ToRevision: x.ToRevision),
        KubeRolloutRestartOperation x => new(Resource(x.Identity), null, Execution(context), Preview: x.Preview.ToString(), FieldManager: x.FieldManager),
        KubeScaleOperation x => new(Resource(x.Identity), null, Execution(context), Preview: x.Preview.ToString(), Replicas: x.Replicas),
        KubeSetImageOperation x => new(Resource(x.Identity), null, Execution(context), Preview: x.Preview.ToString(), FieldManager: x.FieldManager, Container: x.Container, Image: x.Image),
        KubeRolloutStatusOperation x => new(Resource(x.Identity), null, Execution(context), WaitTimeoutMilliseconds: checked((long)x.Timeout.TotalMilliseconds), Revision: x.Revision),
        _ => throw new KubeException(KubeErrorKind.Unsupported, $"kubectl-host does not know operation {operation.GetType().Name}.", code: "kubectl.operation")
    };

    internal static WireProtocol.Method Method(KubeOperation operation) => operation switch
    {
        KubeGetOperation => WireProtocol.Method.Get,
        KubeListOperation => WireProtocol.Method.List,
        KubeCreateOperation => WireProtocol.Method.Create,
        KubeReplaceOperation => WireProtocol.Method.Replace,
        KubeDeleteOperation => WireProtocol.Method.Delete,
        KubePatchOperation => WireProtocol.Method.Patch,
        KubeApplyOperation => WireProtocol.Method.Apply,
        KubeWatchOperation => WireProtocol.Method.WatchStart,
        KubeRolloutUndoOperation => WireProtocol.Method.RolloutUndo,
        KubeRolloutRestartOperation => WireProtocol.Method.RolloutRestart,
        KubeScaleOperation => WireProtocol.Method.Scale,
        KubeSetImageOperation => WireProtocol.Method.SetImage,
        KubeRolloutStatusOperation => WireProtocol.Method.RolloutStatus,
        _ => throw new KubeException(KubeErrorKind.Unsupported, $"kubectl-host does not know operation {operation.GetType().Name}.", code: "kubectl.operation")
    };

    internal static KubeOperationResult Result(WireOperationResponse response)
    {
        List<KubeResource> resources = new();
        foreach (WireResourceResult item in response.Resources ?? Array.Empty<WireResourceResult>())
        {
            JsonObject document = JsonNode.Parse(item.Json.GetRawText())?.AsObject()
                ?? throw new KubeException(KubeErrorKind.Serialization, "kubectl-host returned a non-object Kubernetes resource.", code: "kubectl.response.resource");
            resources.Add(KubeResource.FromDocument(Gvr(item.Gvr), document));
        }
        IEnumerable<KubeWarning> warnings = (response.Warnings ?? Array.Empty<string>()).Select(message => new KubeWarning(message, "kubectl-host.warning", "kubectl"));
        IEnumerable<KubeDiagnostic> diagnostics = (response.Diagnostics ?? new Dictionary<string, string>()).Select(pair => new KubeDiagnostic(pair.Key, pair.Value));
        return new KubeOperationResult(resources, warnings, diagnostics);
    }

    internal static KubeResourceDescriptor Descriptor(WireResourceDescriptor value)
    {
        IEnumerable<KubeSubresourceDescriptor> subs = (value.Subresources ?? Array.Empty<WireSubresourceDescriptor>()).Select(sub =>
            new KubeSubresourceDescriptor(sub.Name, sub.Group, sub.Version, sub.Kind, sub.Namespaced, sub.Verbs));
        return KubeResourceDescriptor.Create(
            Gvr(value.Gvr), value.Kind, value.Namespaced, value.Verbs,
            (value.Subresources ?? Array.Empty<WireSubresourceDescriptor>()).Select(x => x.Name),
            value.SingularName, value.ShortNames, value.Categories, subs);
    }

    internal static KubeException Exception(KubectlWireException exception, KubeTarget? target = null, ResourceIdentity? resource = null)
    {
        WireError error = exception.Error;
        List<KubeDiagnostic> diagnostics = new();
        if (error.HttpStatus != 0) diagnostics.Add(new KubeDiagnostic("kubectl.http-status", error.HttpStatus.ToString()));
        if (error.Retryable is not null) diagnostics.Add(new KubeDiagnostic("kubectl.retryable", error.Retryable.Value.ToString()));
        if (error.Status is not null) diagnostics.Add(new KubeDiagnostic("kubectl.status", error.Status.Value.GetRawText()));
        if (error.Diagnostics is not null)
            diagnostics.AddRange(error.Diagnostics.Select(pair => new KubeDiagnostic(pair.Key, pair.Value)));
        return new KubeException(ErrorKind(error.Class), error.Message, exception, resource, target, error.Code, diagnostics: diagnostics);
    }

    internal static KubeError Error(WireError error) => new(ErrorKind(error.Class), error.Message, error.Code);

    internal static KubeException TransportException(Exception exception, KubeTarget? target, string code) =>
        new(KubeErrorKind.Unavailable, "kubectl-host transport failed: " + exception.Message, exception, target: target, code: code);

    private static WireConcurrency Concurrency(KubeConcurrencyOptions options) => new(options.Mode.ToString(), options.ExpectedResourceVersion);

    private static JsonElement Payload(string json)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            return document.RootElement.Clone();
        }
        catch (JsonException ex)
        {
            throw new KubeException(KubeErrorKind.Serialization, "Kubernetes payload is not valid JSON.", ex, code: "kubectl.payload-json");
        }
    }

    private static KubeErrorKind ErrorKind(string value) => value.ToLowerInvariant() switch
    {
        "notfound" => KubeErrorKind.NotFound,
        "invalid" => KubeErrorKind.InvalidResource,
        "serialization" => KubeErrorKind.Serialization,
        "configuration" or "protocol" => KubeErrorKind.Configuration,
        "authentication" => KubeErrorKind.Authentication,
        "authorization" => KubeErrorKind.Authorization,
        "conflict" => KubeErrorKind.Conflict,
        "unsupported" => KubeErrorKind.Unsupported,
        "unavailable" => KubeErrorKind.Unavailable,
        "cancelled" => KubeErrorKind.Cancelled,
        _ => KubeErrorKind.Transport
    };
}
