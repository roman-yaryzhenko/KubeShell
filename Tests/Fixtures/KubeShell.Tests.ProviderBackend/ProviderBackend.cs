using System.Text.Json.Nodes;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

public static class FixtureState
{
    public static string CurrentContext { get; set; } = "fixture-context";
    public static int GetCalls { get; set; }
    public static int ListCalls { get; set; }
    public static int CreateCalls { get; set; }
    public static int ApplyCalls { get; set; }
    public static int DeleteCalls { get; set; }
    public static int DiscoveryCalls { get; set; }
    public static List<string> GetRequests { get; } = new();
    public static List<string> ListRequests { get; } = new();
    public static string? LastPayloadJson { get; set; }
    public static string[] LastConfigViewPaths { get; set; } = Array.Empty<string>();
    public static bool Disposed { get; set; }
    public static void Reset()
    {
        CurrentContext = "fixture-context";
        GetCalls = ListCalls = CreateCalls = ApplyCalls = DeleteCalls = DiscoveryCalls = 0;
        GetRequests.Clear();
        ListRequests.Clear();
        LastPayloadJson = null;
        LastConfigViewPaths = Array.Empty<string>();
        Disposed = false;
    }
}

public sealed class KubernetesClientBackend : IKubeBackend, IKubeDiscoveryBackend, IKubeConfigBackend, IKubeCapabilityEvaluator, IDisposable
{
    private static readonly KubeResourceDescriptor[] Descriptors =
    {
        D("", "v1", "namespaces", "Namespace", false, "namespace", "ns"),
        D("", "v1", "pods", "Pod", true, "pod", "po"),
        D("apps", "v1", "deployments", "Deployment", true, "deployment", "deploy"),
        D("", "v1", "nodes", "Node", false, "node", "no"),
        D("example.com", "v1", "widgets", "Widget", true, "widget", "wdg")
    };

    public string Id => "provider-contract-fixture";

    public ValueTask<KubeOperationSupport> EvaluateAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromResult(KubeOperationSupport.Supported("fixture.supported"));

    public ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(KubeCapabilityRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        bool supported = request is KubeDiscoveryCapabilityRequest or KubeConfigCapabilityRequest;
        return ValueTask.FromResult(supported
            ? KubeOperationSupport.Supported("fixture.capability")
            : KubeOperationSupport.Unsupported("fixture.capability", request.GetType().Name));
    }

    public ValueTask<KubeConfigView> GetConfigViewAsync(KubeTarget target, CancellationToken cancellationToken = default)
    {
        FixtureState.LastConfigViewPaths = target.KubeConfigPaths;
        return ValueTask.FromResult(new KubeConfigView(FixtureState.CurrentContext, new[]
        {
            new KubeConfigContextInfo("fixture-context", "fixture", "fixture", "default"),
            new KubeConfigContextInfo("other-context", "fixture", "fixture", "monitoring")
        }));
    }

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) =>
        Preferred();

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(string apiVersion, KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) =>
        ApiVersion(apiVersion);

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(GroupVersionResource resource, KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) =>
        Resolve(resource, target);

    public ValueTask<KubeOperationResult> ExecuteAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        switch (operation)
        {
            case KubeGetOperation get:
                FixtureState.GetCalls++;
                FixtureState.GetRequests.Add(RequestKey(get.Identity.Gvr, get.Identity.NamespaceScope, get.Identity.Name));
                ThrowNamedFailure(get.Identity.Name, get.Identity, target);
                if (get.Identity.Name == "missing") throw new KubeException(KubeErrorKind.NotFound, "missing", resource: get.Identity, target: target, code: "fixture.not-found");
                return ValueTask.FromResult(new KubeOperationResult(new[] { MakeResource(get.Identity) }));
            case KubeListOperation list:
                FixtureState.ListCalls++;
                FixtureState.ListRequests.Add(RequestKey(list.Query.Gvr, list.Query.NamespaceScope, list.Query.Name));
                return ValueTask.FromResult(new KubeOperationResult(ListResources(list.Query)));
            case KubeCreateOperation create:
                FixtureState.CreateCalls++;
                FixtureState.LastPayloadJson = create.PayloadJson;
                return ValueTask.FromResult(MutationResult(create.Identity, create.PayloadJson, "created"));
            case KubeApplyOperation apply:
                FixtureState.ApplyCalls++;
                FixtureState.LastPayloadJson = apply.PayloadJson;
                if (apply.Identity.Name == "conflict") throw new KubeException(
                    KubeErrorKind.Conflict,
                    "conflict",
                    resource: apply.Identity,
                    target: target,
                    code: "fixture.conflict",
                    warnings: new[] { new KubeWarning("fixture failure warning", "fixture.failure-warning") },
                    diagnostics: new[] { new KubeDiagnostic("fixture.failure", "fixture failure diagnostic", KubeDiagnosticLevel.Warning) });
                return ValueTask.FromResult(MutationResult(apply.Identity, apply.PayloadJson, "applied"));
            case KubeDeleteOperation delete:
                FixtureState.DeleteCalls++;
                ThrowNamedFailure(delete.Identity.Name, delete.Identity, target);
                return ValueTask.FromResult(new KubeOperationResult(warnings: new[] { new KubeWarning("deleted", "fixture.warning") }, diagnostics: new[] { new KubeDiagnostic("fixture.delete", "deleted") }));
            case KubeReplaceOperation replace:
                return ValueTask.FromResult(MutationResult(replace.Identity, replace.PayloadJson, "replaced"));
            case KubePatchOperation patch:
                return ValueTask.FromResult(MutationResult(patch.Identity, patch.PayloadJson, "patched"));
            default:
                throw new KubeException(KubeErrorKind.Unsupported, operation.GetType().Name, target: target, code: "fixture.unsupported");
        }
    }

    private static string RequestKey(GroupVersionResource gvr, KubeNamespaceScope scope, string? name) =>
        string.Join("|", gvr.Group ?? string.Empty, gvr.Resource, scope.Kind.ToString(), scope.Name ?? string.Empty, name ?? string.Empty);

    private static ValueTask<IReadOnlyList<KubeResourceDescriptor>> Preferred()
    {
        FixtureState.DiscoveryCalls++;
        return ValueTask.FromResult<IReadOnlyList<KubeResourceDescriptor>>(Descriptors);
    }

    private static ValueTask<IReadOnlyList<KubeResourceDescriptor>> ApiVersion(string apiVersion)
    {
        FixtureState.DiscoveryCalls++;
        return ValueTask.FromResult<IReadOnlyList<KubeResourceDescriptor>>(Descriptors.Where(x => string.Equals(x.Gvr.ApiVersion, apiVersion, StringComparison.OrdinalIgnoreCase)).ToArray());
    }

    private static ValueTask<KubeResourceDescriptor?> Resolve(GroupVersionResource resource, KubeTarget target)
    {
        FixtureState.DiscoveryCalls++;
        return ValueTask.FromResult(KubeDiscoveryResolution.Resolve(resource, Descriptors, Descriptors, target, "fixture.ambiguous"));
    }

    public void Dispose() => FixtureState.Disposed = true;

    private static KubeResourceDescriptor D(string group, string version, string resource, string kind, bool namespaced, string singular, params string[] shortNames) =>
        KubeResourceDescriptor.Create(new GroupVersionResource(group, version, resource), kind, namespaced,
            new[] { "get", "list", "create", "patch", "update", "delete" }, singularName: singular, shortNames: shortNames);

    private static IEnumerable<KubeResource> ListResources(ResourceQuery query)
    {
        if (query.Gvr.Resource == "namespaces")
            return new[] { MakeResource(new ResourceIdentity(new GroupVersionResource("", "v1", "namespaces"), "default", KubeNamespaceScope.Cluster, kind: "Namespace")), MakeResource(new ResourceIdentity(new GroupVersionResource("", "v1", "namespaces"), "monitoring", KubeNamespaceScope.Cluster, kind: "Namespace")) };
        if (query.Gvr.Resource == "nodes")
            return new[] { MakeResource(new ResourceIdentity(new GroupVersionResource("", "v1", "nodes"), "node-a", KubeNamespaceScope.Cluster, kind: "Node")) };
        string ns = query.NamespaceScope.Kind == KubeNamespaceScopeKind.Explicit ? query.NamespaceScope.Name! : "default";
        if (query.NamespaceScope.Kind == KubeNamespaceScopeKind.All)
            return new[] { Pod("default", "shared"), Pod("monitoring", "shared") };
        if (query.Gvr.Resource == "pods") return new[] { Pod(ns, "shared"), Pod(ns, "api") };
        if (query.Gvr.Resource == "deployments") return new[] { MakeResource(new ResourceIdentity(new GroupVersionResource("apps", "v1", "deployments"), "web", KubeNamespaceScope.Explicit(ns), kind: "Deployment")) };
        if (query.Gvr.Resource == "widgets") return new[] { MakeResource(new ResourceIdentity(new GroupVersionResource("example.com", "v1", "widgets"), "sample", KubeNamespaceScope.Explicit(ns), kind: "Widget")) };
        return Array.Empty<KubeResource>();
    }

    private static KubeResource Pod(string ns, string name) => MakeResource(new ResourceIdentity(new GroupVersionResource("", "v1", "pods"), name, KubeNamespaceScope.Explicit(ns), kind: "Pod"));

    private static KubeResource MakeResource(ResourceIdentity identity)
    {
        KubeResourceDescriptor? descriptor = Descriptors.FirstOrDefault(x => x.Gvr == identity.Gvr);
        string kind = identity.Kind ?? descriptor?.Kind ?? "Fixture";
        ResourceIdentity responseIdentity = identity.Kind is null && descriptor is not null
            ? new ResourceIdentity(identity.Gvr, identity.Name, identity.NamespaceScope, identity.Subresource, descriptor.Kind)
            : identity;

        JsonObject metadata = new() { ["name"] = responseIdentity.Name };
        if (responseIdentity.Namespace is not null) metadata["namespace"] = responseIdentity.Namespace;
        return new KubeResource(responseIdentity, new JsonObject
        {
            ["apiVersion"] = responseIdentity.Gvr.ApiVersion,
            ["kind"] = kind,
            ["metadata"] = metadata
        });
    }

    private static KubeOperationResult MutationResult(ResourceIdentity identity, string payload, string diagnostic)
    {
        JsonObject doc = JsonNode.Parse(payload)?.AsObject() ?? new JsonObject();
        return new KubeOperationResult(new[] { new KubeResource(identity, doc) },
            new[] { new KubeWarning("fixture warning", "fixture.warning") },
            new[] { new KubeDiagnostic("fixture." + diagnostic, diagnostic) });
    }

    private static void ThrowNamedFailure(string name, ResourceIdentity identity, KubeTarget target)
    {
        if (name == "unauthenticated") throw new KubeException(KubeErrorKind.Authentication, "unauthenticated", resource: identity, target: target, code: "fixture.authentication");
        if (name == "forbidden") throw new KubeException(KubeErrorKind.Authorization, "forbidden", resource: identity, target: target, code: "fixture.authorization");
        if (name == "unavailable") throw new KubeException(KubeErrorKind.Unavailable, "unavailable", resource: identity, target: target, code: "fixture.unavailable");
    }
}
