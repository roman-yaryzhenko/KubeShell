using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using k8s.Autorest;
using k8s.Models;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

/// <summary>Executes already-approved Runtime operations through KubernetesClient's generated APIs.</summary>
internal sealed class KubernetesOperationExecutor
{
    private readonly KubernetesSessionFactory _sessions;

    public KubernetesOperationExecutor(KubernetesSessionFactory sessions)
    {
        _sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
    }

    public async ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        using CancellationTokenSource? timeout = KubernetesRequestContext.CreateTimeoutSource(executionContext.Timeout, cancellationToken);
        CancellationToken effectiveToken = timeout?.Token ?? cancellationToken;

        try
        {
            using ManagedSession session = _sessions.Create(target);
            IReadOnlyDictionary<string, IReadOnlyList<string>>? headers = KubernetesRequestContext.BuildHeaders(executionContext);
            string? fieldValidation = FieldValidation(executionContext.FieldValidation);
            return operation switch
            {
                KubeGetOperation get => await GetAsync(session, get, target, headers, effectiveToken).ConfigureAwait(false),
                KubeListOperation list => await ListAsync(session, list, target, headers, effectiveToken).ConfigureAwait(false),
                KubeCreateOperation create => await CreateAsync(session, create, target, fieldValidation, headers, effectiveToken).ConfigureAwait(false),
                KubeReplaceOperation replace => await ReplaceAsync(session, replace, target, fieldValidation, headers, effectiveToken).ConfigureAwait(false),
                KubeApplyOperation apply => await ApplyAsync(session, apply, target, fieldValidation, headers, effectiveToken).ConfigureAwait(false),
                KubePatchOperation patch => await PatchAsync(session, patch, target, fieldValidation, headers, effectiveToken).ConfigureAwait(false),
                KubeDeleteOperation delete => await DeleteAsync(session, delete, target, headers, effectiveToken).ConfigureAwait(false),
                _ => throw new KubeException(KubeErrorKind.Unsupported, $"Managed backend does not implement {operation.GetType().Name}.", code: "managed.operation", target: target)
            };
        }
        catch (KubeException) { throw; }
        catch (HttpOperationException ex)
        {
            throw KubernetesResponseMapper.FromHttpException(ex, target, GetIdentity(operation));
        }
        catch (OperationCanceledException ex)
        {
            throw new KubeException(KubeErrorKind.Cancelled, "Kubernetes API operation was cancelled.", ex, target: target, code: "managed.cancelled");
        }
    }

    private static async Task<KubeOperationResult> GetAsync(ManagedSession session, KubeGetOperation operation, KubeTarget target,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceIdentity i = operation.Identity;
        string? ns = KubernetesRequestContext.ResolveNamespace(i.NamespaceScope, target, session.Configuration);
        using HttpOperationResponse<JsonElement> response = i.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster
            ? await session.Client.CustomObjects.GetClusterCustomObjectWithHttpMessagesAsync<JsonElement>(i.Gvr.Group, i.Gvr.Version, i.Gvr.Resource, i.Name, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.GetNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(i.Gvr.Group, i.Gvr.Version, ns!, i.Gvr.Resource, i.Name, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, i.Gvr);
    }

    private static async Task<KubeOperationResult> ListAsync(ManagedSession session, KubeListOperation operation, KubeTarget target,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceQuery q = operation.Query;
        string? ns = KubernetesRequestContext.ResolveNamespace(q.NamespaceScope, target, session.Configuration);
        bool clusterEndpoint = q.NamespaceScope.Kind is KubeNamespaceScopeKind.All or KubeNamespaceScopeKind.Cluster;
        using HttpOperationResponse<JsonElement> response = clusterEndpoint
            ? await session.Client.CustomObjects.ListClusterCustomObjectWithHttpMessagesAsync<JsonElement>(q.Gvr.Group, q.Gvr.Version, q.Gvr.Resource,
                fieldSelector: q.FieldSelector, labelSelector: q.LabelSelector, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.ListNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(q.Gvr.Group, q.Gvr.Version, ns!, q.Gvr.Resource,
                fieldSelector: q.FieldSelector, labelSelector: q.LabelSelector, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, q.Gvr);
    }

    private static async Task<KubeOperationResult> CreateAsync(ManagedSession session, KubeCreateOperation operation, KubeTarget target, string? fieldValidation,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceIdentity i = operation.Identity;
        JsonElement body = ParseElement(operation.PayloadJson);
        string? ns = KubernetesRequestContext.ResolveNamespace(i.NamespaceScope, target, session.Configuration);
        string? dryRun = ServerDryRun(operation.Options.Preview);
        using HttpOperationResponse<JsonElement> response = i.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster
            ? await session.Client.CustomObjects.CreateClusterCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, i.Gvr.Resource,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.CreateNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, ns!, i.Gvr.Resource,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, i.Gvr);
    }

    private static async Task<KubeOperationResult> ReplaceAsync(ManagedSession session, KubeReplaceOperation operation, KubeTarget target, string? fieldValidation,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceIdentity i = operation.Identity;
        JsonElement body = ParseElement(ApplyExpectedResourceVersion(operation.PayloadJson, operation.Options.Concurrency));
        string? ns = KubernetesRequestContext.ResolveNamespace(i.NamespaceScope, target, session.Configuration);
        string? dryRun = ServerDryRun(operation.Options.Preview);
        using HttpOperationResponse<JsonElement> response = i.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster
            ? await session.Client.CustomObjects.ReplaceClusterCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, i.Gvr.Resource, i.Name,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.ReplaceNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, ns!, i.Gvr.Resource, i.Name,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, i.Gvr);
    }

    private static async Task<KubeOperationResult> ApplyAsync(ManagedSession session, KubeApplyOperation operation, KubeTarget target, string? fieldValidation,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceIdentity i = operation.Identity;
        V1Patch body = new(operation.PayloadJson, V1Patch.PatchType.ApplyPatch);
        string? ns = KubernetesRequestContext.ResolveNamespace(i.NamespaceScope, target, session.Configuration);
        string? dryRun = ServerDryRun(operation.Options.Preview);
        using HttpOperationResponse<JsonElement> response = i.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster
            ? await session.Client.CustomObjects.PatchClusterCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, i.Gvr.Resource, i.Name,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, force: operation.Options.ForceConflicts, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.PatchNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, ns!, i.Gvr.Resource, i.Name,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, force: operation.Options.ForceConflicts, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, i.Gvr);
    }

    private static async Task<KubeOperationResult> PatchAsync(ManagedSession session, KubePatchOperation operation, KubeTarget target, string? fieldValidation,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceIdentity i = operation.Identity;
        V1Patch body = new(operation.PayloadJson, operation.Options.Type switch
        {
            KubePatchType.Json => V1Patch.PatchType.JsonPatch,
            KubePatchType.Strategic => V1Patch.PatchType.StrategicMergePatch,
            _ => V1Patch.PatchType.MergePatch
        });
        string? ns = KubernetesRequestContext.ResolveNamespace(i.NamespaceScope, target, session.Configuration);
        string? dryRun = ServerDryRun(operation.Options.Preview);
        using HttpOperationResponse<JsonElement> response = i.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster
            ? await session.Client.CustomObjects.PatchClusterCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, i.Gvr.Resource, i.Name,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.PatchNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(body, i.Gvr.Group, i.Gvr.Version, ns!, i.Gvr.Resource, i.Name,
                dryRun: dryRun, fieldManager: operation.Options.FieldManager, fieldValidation: fieldValidation, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, i.Gvr);
    }

    private static async Task<KubeOperationResult> DeleteAsync(ManagedSession session, KubeDeleteOperation operation, KubeTarget target,
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers, CancellationToken ct)
    {
        ResourceIdentity i = operation.Identity;
        string? ns = KubernetesRequestContext.ResolveNamespace(i.NamespaceScope, target, session.Configuration);
        string? dryRun = ServerDryRun(operation.Options.Preview);
        int? grace = operation.Options.Force ? 0 : operation.Options.GracePeriodSeconds;
        using HttpOperationResponse<JsonElement> response = i.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster
            ? await session.Client.CustomObjects.DeleteClusterCustomObjectWithHttpMessagesAsync<JsonElement>(i.Gvr.Group, i.Gvr.Version, i.Gvr.Resource, i.Name,
                gracePeriodSeconds: grace, dryRun: dryRun, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false)
            : await session.Client.CustomObjects.DeleteNamespacedCustomObjectWithHttpMessagesAsync<JsonElement>(i.Gvr.Group, i.Gvr.Version, ns!, i.Gvr.Resource, i.Name,
                gracePeriodSeconds: grace, dryRun: dryRun, customHeaders: headers, cancellationToken: ct).ConfigureAwait(false);
        return KubernetesResponseMapper.Result(response, i.Gvr, tolerateStatusObject: true);
    }

    private static string ApplyExpectedResourceVersion(string payloadJson, KubeConcurrencyOptions concurrency)
    {
        if (concurrency.Mode != KubeConcurrencyMode.RequireUnchanged) return payloadJson;
        if (string.IsNullOrWhiteSpace(concurrency.ExpectedResourceVersion))
            throw new KubeException(KubeErrorKind.InvalidResource, "RequireUnchanged needs ExpectedResourceVersion.", code: "concurrency.resource-version-required");
        JsonObject root = JsonNode.Parse(payloadJson)?.AsObject() ?? throw new KubeException(KubeErrorKind.Serialization, "Replace payload must be a JSON object.");
        JsonObject metadata = root["metadata"] as JsonObject ?? new JsonObject();
        root["metadata"] = metadata;
        metadata["resourceVersion"] = concurrency.ExpectedResourceVersion;
        return root.ToJsonString();
    }

    private static JsonElement ParseElement(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private static string? ServerDryRun(KubePreviewMode preview) => preview == KubePreviewMode.Server ? "All" : null;

    private static string? FieldValidation(KubeFieldValidationMode mode) => mode switch
    {
        KubeFieldValidationMode.Ignore => "Ignore",
        KubeFieldValidationMode.Warn => "Warn",
        KubeFieldValidationMode.Strict => "Strict",
        _ => null
    };

    private static ResourceIdentity? GetIdentity(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => x.Identity,
        KubeCreateOperation x => x.Identity,
        KubeReplaceOperation x => x.Identity,
        KubeApplyOperation x => x.Identity,
        KubePatchOperation x => x.Identity,
        KubeDeleteOperation x => x.Identity,
        _ => null
    };
}
