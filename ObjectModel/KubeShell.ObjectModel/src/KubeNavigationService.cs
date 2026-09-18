using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using KubeShell.Runtime;

namespace KubeShell.ObjectModel;

public interface IKubeNavigationService
{
    KubeTarget Target { get; }
    TargetRootLocator TargetRoot { get; }

    ValueTask<KubeNodeLocator> CreateRootLocatorAsync(KubeMountRequest request, CancellationToken cancellationToken = default);
    ValueTask<IReadOnlyList<KubeNavigationNode>> GetChildrenAsync(KubeNodeLocator locator, bool refresh = false, CancellationToken cancellationToken = default);
    ValueTask<IReadOnlyList<string>> GetChildNamesAsync(KubeNodeLocator locator, bool refresh = false, CancellationToken cancellationToken = default);
    ValueTask<KubeNavigationNode?> ResolveChildAsync(KubeNodeLocator parent, string name, bool refresh = false, CancellationToken cancellationToken = default);
    ValueTask<KubeNavigationNode?> GetItemAsync(KubeNodeLocator locator, CancellationToken cancellationToken = default);
    ValueTask<KubeResourceDescriptor> ResolveResourceAliasAsync(string token, CancellationToken cancellationToken = default);
    IReadOnlyList<ObjectOperationDescriptor> GetOperations(KubeNavigationNode node);

    ValueTask<KubeExecutionResult<KubeNavigationNode>> CreateAsync(ResourceItemLocator locator, string payloadJson, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult<KubeNavigationNode>> ApplyAsync(ResourceItemLocator locator, string payloadJson, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult> DeleteAsync(ResourceItemLocator locator, KubeDeleteOptions? options = null, CancellationToken cancellationToken = default);
    void Invalidate(KubeNodeLocator locator);
}

/// <summary>
/// Frontend-neutral discovery-driven navigation/application service. It owns navigation topology and
/// semantic resource resolution; Runtime remains the source of Kubernetes execution semantics.
/// </summary>
public sealed class KubeNavigationService : IKubeNavigationService
{
    private readonly IKubeResourceClient _resources;
    private readonly IKubeResourceExecutionClient _execution;
    private readonly IKubeDiscoveryClient _discovery;
    private readonly KubeExecutionContext _executionContext;
    private readonly ConcurrentDictionary<KubeNodeLocator, IReadOnlyList<KubeNavigationNode>> _navigationCache = new();

    public KubeNavigationService(
        KubeTarget target,
        IKubeResourceClient resources,
        IKubeResourceExecutionClient execution,
        IKubeDiscoveryClient discovery,
        KubeExecutionContext? executionContext = null)
    {
        Target = target ?? throw new ArgumentNullException(nameof(target));
        _resources = resources ?? throw new ArgumentNullException(nameof(resources));
        _execution = execution ?? throw new ArgumentNullException(nameof(execution));
        _discovery = discovery ?? throw new ArgumentNullException(nameof(discovery));
        _executionContext = executionContext ?? KubeExecutionContext.Default;
        TargetRoot = new TargetRootLocator(KubeTargetIdentity.Create(Target));
    }

    public KubeTarget Target { get; }
    public TargetRootLocator TargetRoot { get; }

    public async ValueTask<KubeNodeLocator> CreateRootLocatorAsync(KubeMountRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!string.IsNullOrWhiteSpace(request.Namespace) && request.AllNamespaces)
            throw InvalidMount("-Namespace and -AllNamespaces are mutually exclusive.");
        if (request.AllNamespaces && string.IsNullOrWhiteSpace(request.Resource))
            throw InvalidMount("-AllNamespaces requires -Resource.");

        if (string.IsNullOrWhiteSpace(request.Resource))
        {
            return string.IsNullOrWhiteSpace(request.Namespace)
                ? TargetRoot
                : new NamespaceLocator(TargetRoot.TargetKey, request.Namespace.Trim());
        }

        KubeResourceDescriptor descriptor = await ResolveResourceAliasAsync(request.Resource, cancellationToken).ConfigureAwait(false);
        GroupResource resource = GroupResource.From(descriptor.Gvr);

        if (descriptor.Namespaced)
        {
            if (string.IsNullOrWhiteSpace(request.Namespace) && !request.AllNamespaces)
                throw InvalidMount($"Namespaced resource '{resource}' requires -Namespace or -AllNamespaces.");
            KubeNamespaceScope scope = request.AllNamespaces
                ? KubeNamespaceScope.All
                : KubeNamespaceScope.Explicit(request.Namespace!.Trim());
            return new ResourceCollectionLocator(TargetRoot.TargetKey, resource, scope);
        }

        if (!string.IsNullOrWhiteSpace(request.Namespace) || request.AllNamespaces)
            throw InvalidMount($"Cluster-scoped resource '{resource}' does not accept namespace scope.");
        return new ResourceCollectionLocator(TargetRoot.TargetKey, resource, KubeNamespaceScope.Cluster);
    }

    public async ValueTask<IReadOnlyList<KubeNavigationNode>> GetChildrenAsync(
        KubeNodeLocator locator,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        ValidateTarget(locator);
        if (refresh) Invalidate(locator);
        if (IsTopologyCacheable(locator) && _navigationCache.TryGetValue(locator, out IReadOnlyList<KubeNavigationNode>? cached))
            return cached;

        IReadOnlyList<KubeNavigationNode> children = locator switch
        {
            TargetRootLocator => BuildTargetRoot(),
            NamespacesRootLocator => await GetNamespacesAsync(refresh, cancellationToken).ConfigureAwait(false),
            NamespaceLocator ns => await GetResourceCollectionsAsync(ns, namespaced: true, refresh, cancellationToken).ConfigureAwait(false),
            ClusterRootLocator cluster => await GetResourceCollectionsAsync(cluster, namespaced: false, refresh, cancellationToken).ConfigureAwait(false),
            ResourceCollectionLocator collection => await GetCollectionChildrenAsync(collection, refresh, cancellationToken).ConfigureAwait(false),
            ResourceNamespaceBucketLocator bucket => await GetBucketChildrenAsync(bucket, refresh, cancellationToken).ConfigureAwait(false),
            ResourceItemLocator => Array.Empty<KubeNavigationNode>(),
            _ => throw new ArgumentOutOfRangeException(nameof(locator))
        };

        if (IsTopologyCacheable(locator)) _navigationCache[locator] = children;
        return children;
    }

    public async ValueTask<IReadOnlyList<string>> GetChildNamesAsync(
        KubeNodeLocator locator,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        ValidateTarget(locator);
        if (refresh) Invalidate(locator);

        if (locator is ResourceCollectionLocator collection && collection.Scope.Kind != KubeNamespaceScopeKind.All)
        {
            KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(collection.Resource, refresh, cancellationToken).ConfigureAwait(false);
            EnsureScopeCompatible(collection.Scope, descriptor);
            return await _resources.ListNamesAsync(Target, new ResourceQuery(descriptor.Gvr, namespaceScope: collection.Scope), _executionContext, cancellationToken).ConfigureAwait(false);
        }

        if (locator is ResourceNamespaceBucketLocator bucket)
        {
            KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(bucket.Resource, refresh, cancellationToken).ConfigureAwait(false);
            KubeNamespaceScope scope = KubeNamespaceScope.Explicit(bucket.Namespace);
            EnsureScopeCompatible(scope, descriptor);
            IReadOnlyList<string> names = await _resources.ListNamesAsync(
                Target,
                new ResourceQuery(descriptor.Gvr, namespaceScope: scope),
                _executionContext,
                cancellationToken).ConfigureAwait(false);
            return names.OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
        }

        return (await GetChildrenAsync(locator, refresh, cancellationToken).ConfigureAwait(false))
            .Select(child => child.Name)
            .ToArray();
    }

    public async ValueTask<KubeNavigationNode?> ResolveChildAsync(
        KubeNodeLocator parent,
        string name,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        ValidateTarget(parent);

        // A known namespace path is a virtual semantic edge. Resolving it must not require
        // cluster-wide namespace listing: a principal may be authorized inside a known namespace
        // while lacking permission to list namespace objects. Enumerating Namespaces\ still lists.
        if (parent is NamespacesRootLocator)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return MaterializeVirtual(new NamespaceLocator(TargetRoot.TargetKey, name.Trim()));
        }

        // A known namespace bucket inside an all-namespaces collection is also a virtual semantic
        // edge. Resolving Pods:\payments must not require list across every namespace merely to
        // prove that the bucket can be addressed. Enumerating the collection remains a live
        // all-namespaces list and therefore still shows only non-empty buckets.
        if (parent is ResourceCollectionLocator allCollection && allCollection.Scope.Kind == KubeNamespaceScopeKind.All)
        {
            cancellationToken.ThrowIfCancellationRequested();
            KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(allCollection.Resource, refresh, cancellationToken).ConfigureAwait(false);
            EnsureScopeCompatible(allCollection.Scope, descriptor);
            return MaterializeBucket(
                new ResourceNamespaceBucketLocator(TargetRoot.TargetKey, allCollection.Resource, name.Trim()),
                descriptor);
        }

        // A known item path is a point-read semantic edge. Do not list the entire collection
        // merely to resolve one child: that would require list RBAC where get is sufficient and
        // would turn Get-Item/ItemExists into O(collection) operations.
        if (parent is ResourceCollectionLocator collection && collection.Scope.Kind != KubeNamespaceScopeKind.All)
        {
            KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(collection.Resource, refresh, cancellationToken).ConfigureAwait(false);
            EnsureScopeCompatible(collection.Scope, descriptor);
            KubeResource? value = await _resources.TryGetAsync(
                Target,
                new ResourceQuery(descriptor.Gvr, name, collection.Scope),
                _executionContext,
                cancellationToken).ConfigureAwait(false);
            return value is null ? null : MaterializeResource(value, descriptor);
        }

        if (parent is ResourceNamespaceBucketLocator bucket)
        {
            KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(bucket.Resource, refresh, cancellationToken).ConfigureAwait(false);
            KubeNamespaceScope scope = KubeNamespaceScope.Explicit(bucket.Namespace);
            EnsureScopeCompatible(scope, descriptor);
            KubeResource? value = await _resources.TryGetAsync(
                Target,
                new ResourceQuery(descriptor.Gvr, name, scope),
                _executionContext,
                cancellationToken).ConfigureAwait(false);
            return value is null ? null : MaterializeResource(value, descriptor);
        }

        IReadOnlyList<KubeNavigationNode> children = await GetChildrenAsync(parent, refresh, cancellationToken).ConfigureAwait(false);
        return children.FirstOrDefault(child => string.Equals(child.Name, name, StringComparison.OrdinalIgnoreCase));
    }

    public async ValueTask<KubeNavigationNode?> GetItemAsync(KubeNodeLocator locator, CancellationToken cancellationToken = default)
    {
        ValidateTarget(locator);
        if (locator is ResourceCollectionLocator collection)
        {
            KubeResourceDescriptor collectionDescriptor = await ResolvePreferredDescriptorAsync(collection.Resource, false, cancellationToken).ConfigureAwait(false);
            EnsureScopeCompatible(collection.Scope, collectionDescriptor);
            return MaterializeCollection(collection, collectionDescriptor);
        }
        if (locator is ResourceNamespaceBucketLocator bucket)
        {
            KubeResourceDescriptor bucketDescriptor = await ResolvePreferredDescriptorAsync(bucket.Resource, false, cancellationToken).ConfigureAwait(false);
            EnsureScopeCompatible(KubeNamespaceScope.Explicit(bucket.Namespace), bucketDescriptor);
            return MaterializeBucket(bucket, bucketDescriptor);
        }
        if (locator is not ResourceItemLocator item)
            return MaterializeVirtual(locator);

        KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(item.Resource, false, cancellationToken).ConfigureAwait(false);
        EnsureScopeCompatible(item.Scope, descriptor);
        ResourceQuery query = new(descriptor.Gvr, item.Name, item.Scope);
        KubeResource? value = await _resources.TryGetAsync(Target, query, _executionContext, cancellationToken).ConfigureAwait(false);
        return value is null ? null : MaterializeResource(value, descriptor);
    }

    public async ValueTask<KubeResourceDescriptor> ResolveResourceAliasAsync(string token, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("Resource token is required.", nameof(token));
        string candidate = token.Trim();
        KubeResourceDescriptor? descriptor = await _discovery.ResolveResourceAsync(
            Target,
            new GroupVersionResource(string.Empty, string.Empty, candidate),
            _executionContext,
            false,
            cancellationToken).ConfigureAwait(false);
        return descriptor ?? throw new KubeException(
            KubeErrorKind.InvalidResource,
            $"Kubernetes resource alias '{candidate}' was not found.",
            target: Target,
            code: "navigation.resource-not-found");
    }

    public IReadOnlyList<ObjectOperationDescriptor> GetOperations(KubeNavigationNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        List<ObjectOperationDescriptor> result = new();
        if ((node.Capabilities & KubeNavigationCapabilities.Creatable) != 0)
            result.Add(new("create", "Create", ObjectOperationCardinality.Single, ObjectOperationAvailability.Available));
        if ((node.Capabilities & KubeNavigationCapabilities.Editable) != 0)
            result.Add(new("edit", "Edit", ObjectOperationCardinality.Multiple, ObjectOperationAvailability.Available));
        if ((node.Capabilities & KubeNavigationCapabilities.Deletable) != 0)
            result.Add(new("delete", "Delete", ObjectOperationCardinality.Multiple, ObjectOperationAvailability.Available));
        return result;
    }

    public async ValueTask<KubeExecutionResult<KubeNavigationNode>> CreateAsync(ResourceItemLocator locator, string payloadJson, CancellationToken cancellationToken = default)
    {
        ValidateTarget(locator);
        KubeResourceDescriptor descriptor = await ResolveOperationDescriptorAsync(locator.Resource, cancellationToken).ConfigureAwait(false);
        ResourceIdentity identity = BuildIdentity(locator, descriptor);
        KubeExecutionResult<KubeResource> result = await _execution.CreateAsync(Target, identity, payloadJson, null, _executionContext, cancellationToken).ConfigureAwait(false);
        return ProjectResult(result, descriptor);
    }

    public async ValueTask<KubeExecutionResult<KubeNavigationNode>> ApplyAsync(ResourceItemLocator locator, string payloadJson, CancellationToken cancellationToken = default)
    {
        ValidateTarget(locator);
        KubeResourceDescriptor descriptor = await ResolveOperationDescriptorAsync(locator.Resource, cancellationToken).ConfigureAwait(false);
        ResourceIdentity identity = BuildIdentity(locator, descriptor);
        KubeExecutionResult<KubeResource> result = await _execution.ApplyAsync(Target, identity, payloadJson, null, _executionContext, cancellationToken).ConfigureAwait(false);
        return ProjectResult(result, descriptor);
    }

    public async ValueTask<KubeExecutionResult> DeleteAsync(ResourceItemLocator locator, KubeDeleteOptions? options = null, CancellationToken cancellationToken = default)
    {
        ValidateTarget(locator);
        KubeResourceDescriptor descriptor = await ResolveOperationDescriptorAsync(locator.Resource, cancellationToken).ConfigureAwait(false);
        return await _execution.DeleteAsync(Target, BuildIdentity(locator, descriptor), options, _executionContext, cancellationToken).ConfigureAwait(false);
    }

    public void Invalidate(KubeNodeLocator locator)
    {
        ValidateTarget(locator);
        _navigationCache.TryRemove(locator, out _);
    }

    private IReadOnlyList<KubeNavigationNode> BuildTargetRoot() => new[]
    {
        MaterializeVirtual(new NamespacesRootLocator(TargetRoot.TargetKey)),
        MaterializeVirtual(new ClusterRootLocator(TargetRoot.TargetKey))
    };

    private async ValueTask<IReadOnlyList<KubeNavigationNode>> GetNamespacesAsync(bool refreshDiscovery, CancellationToken cancellationToken)
    {
        KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(new GroupResource(string.Empty, "namespaces"), refreshDiscovery, cancellationToken).ConfigureAwait(false);
        IReadOnlyList<string> names = await _resources.ListNamesAsync(Target, new ResourceQuery(descriptor.Gvr, namespaceScope: KubeNamespaceScope.Cluster), _executionContext, cancellationToken).ConfigureAwait(false);
        return names.OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .Select(name => MaterializeVirtual(new NamespaceLocator(TargetRoot.TargetKey, name)))
            .ToArray();
    }

    private async ValueTask<IReadOnlyList<KubeNavigationNode>> GetResourceCollectionsAsync(KubeNodeLocator parent, bool namespaced, bool refreshDiscovery, CancellationToken cancellationToken)
    {
        IReadOnlyList<KubeResourceDescriptor> descriptors = await _discovery.GetPreferredResourcesAsync(Target, _executionContext, refreshDiscovery, cancellationToken).ConfigureAwait(false);
        KubeNamespaceScope scope = parent switch
        {
            NamespaceLocator ns => KubeNamespaceScope.Explicit(ns.Namespace),
            ClusterRootLocator => KubeNamespaceScope.Cluster,
            _ => throw new ArgumentOutOfRangeException(nameof(parent))
        };

        return descriptors
            .Where(d => d.Namespaced == namespaced && !d.Gvr.Resource.Contains("/", StringComparison.Ordinal))
            .GroupBy(d => GroupResource.From(d.Gvr))
            .Select(group => group.First())
            .OrderBy(d => GroupResource.From(d.Gvr).ToString(), StringComparer.OrdinalIgnoreCase)
            .Select(d => MaterializeCollection(new ResourceCollectionLocator(TargetRoot.TargetKey, GroupResource.From(d.Gvr), scope), d))
            .ToArray();
    }

    private async ValueTask<IReadOnlyList<KubeNavigationNode>> GetCollectionChildrenAsync(ResourceCollectionLocator collection, bool refreshDiscovery, CancellationToken cancellationToken)
    {
        KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(collection.Resource, refreshDiscovery, cancellationToken).ConfigureAwait(false);
        EnsureScopeCompatible(collection.Scope, descriptor);
        IReadOnlyList<KubeResource> values = await _resources.GetAsync(Target, new ResourceQuery(descriptor.Gvr, namespaceScope: collection.Scope), _executionContext, cancellationToken).ConfigureAwait(false);

        if (collection.Scope.Kind == KubeNamespaceScopeKind.All)
        {
            return values
                .Select(value => value.Identity.Namespace)
                .Where(ns => !string.IsNullOrWhiteSpace(ns))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(ns => ns, StringComparer.OrdinalIgnoreCase)
                .Select(ns => MaterializeBucket(new ResourceNamespaceBucketLocator(TargetRoot.TargetKey, collection.Resource, ns!), descriptor))
                .ToArray();
        }

        return values.OrderBy(value => value.Identity.Name, StringComparer.OrdinalIgnoreCase)
            .Select(value => MaterializeResource(value, descriptor))
            .ToArray();
    }

    private async ValueTask<IReadOnlyList<KubeNavigationNode>> GetBucketChildrenAsync(ResourceNamespaceBucketLocator bucket, bool refreshDiscovery, CancellationToken cancellationToken)
    {
        KubeResourceDescriptor descriptor = await ResolvePreferredDescriptorAsync(bucket.Resource, refreshDiscovery, cancellationToken).ConfigureAwait(false);
        KubeNamespaceScope scope = KubeNamespaceScope.Explicit(bucket.Namespace);
        EnsureScopeCompatible(scope, descriptor);
        IReadOnlyList<KubeResource> values = await _resources.GetAsync(
            Target,
            new ResourceQuery(descriptor.Gvr, namespaceScope: scope),
            _executionContext,
            cancellationToken).ConfigureAwait(false);
        return values
            .OrderBy(value => value.Identity.Name, StringComparer.OrdinalIgnoreCase)
            .Select(value => MaterializeResource(value, descriptor))
            .ToArray();
    }

    private ValueTask<KubeResourceDescriptor> ResolveOperationDescriptorAsync(GroupResource resource, CancellationToken cancellationToken)
    {
        // D7: a long-lived version-neutral locator must execute against the server's current
        // preferred served version. Asking for a fresh semantic discovery snapshot here leaves
        // cache mechanics with the selected backend while preventing stale executable GVRs.
        return ResolvePreferredDescriptorAsync(resource, refreshDiscovery: true, cancellationToken);
    }

    private async ValueTask<KubeResourceDescriptor> ResolvePreferredDescriptorAsync(GroupResource resource, bool refreshDiscovery, CancellationToken cancellationToken)
    {
        IReadOnlyList<KubeResourceDescriptor> all = await _discovery.GetPreferredResourcesAsync(Target, _executionContext, refreshDiscovery, cancellationToken).ConfigureAwait(false);
        KubeResourceDescriptor? descriptor = all.FirstOrDefault(d => SameResource(GroupResource.From(d.Gvr), resource));
        if (descriptor is not null) return descriptor;

        // Generic unresolved discovery uses an empty group as an alias wildcard. That is safe for
        // an explicitly grouped canonical resource, but a canonical core GroupResource also uses
        // an empty group. Feeding the latter into the generic resolver could silently switch API
        // groups when preferred discovery is partial. Core identity therefore fails closed here.
        if (!string.IsNullOrWhiteSpace(resource.Group))
        {
            descriptor = await _discovery.ResolveResourceAsync(
                Target,
                new GroupVersionResource(resource.Group, string.Empty, resource.Resource),
                _executionContext,
                refreshDiscovery,
                cancellationToken).ConfigureAwait(false);
            if (descriptor is not null && SameResource(GroupResource.From(descriptor.Gvr), resource))
                return descriptor;
        }

        throw new KubeException(KubeErrorKind.InvalidResource, $"Kubernetes resource '{resource}' is not available through discovery.", target: Target, code: "navigation.resource-not-found");
    }

    private KubeNavigationNode MaterializeVirtual(KubeNodeLocator locator)
    {
        (string name, KubeNavigationCapabilities capabilities) = locator switch
        {
            TargetRootLocator => ("Kube", KubeNavigationCapabilities.Container | KubeNavigationCapabilities.Refreshable),
            NamespacesRootLocator => ("Namespaces", KubeNavigationCapabilities.Container | KubeNavigationCapabilities.Refreshable),
            NamespaceLocator ns => (ns.Namespace, KubeNavigationCapabilities.Container | KubeNavigationCapabilities.Refreshable),
            ClusterRootLocator => ("Cluster", KubeNavigationCapabilities.Container | KubeNavigationCapabilities.Refreshable),
            _ => throw new ArgumentException("Locator is not a virtual navigation node.", nameof(locator))
        };
        return new KubeNavigationNode(locator, name, name, locator.Kind, capabilities);
    }

    private KubeNavigationNode MaterializeCollection(ResourceCollectionLocator locator, KubeResourceDescriptor descriptor)
    {
        KubeNavigationCapabilities capabilities = KubeNavigationCapabilities.Container | KubeNavigationCapabilities.Refreshable;
        if (locator.Scope.Kind != KubeNamespaceScopeKind.All && descriptor.Verbs.Contains("create"))
            capabilities |= KubeNavigationCapabilities.Creatable;
        return new KubeNavigationNode(locator, locator.Resource.ToString(), locator.Resource.ToString(), locator.Kind, capabilities,
            metadata: DescriptorMetadata(descriptor));
    }

    private KubeNavigationNode MaterializeBucket(ResourceNamespaceBucketLocator locator, KubeResourceDescriptor descriptor)
    {
        KubeNavigationCapabilities capabilities = KubeNavigationCapabilities.Container | KubeNavigationCapabilities.Refreshable;
        if (descriptor.Verbs.Contains("create")) capabilities |= KubeNavigationCapabilities.Creatable;
        return new KubeNavigationNode(
            locator,
            locator.Namespace,
            locator.Namespace,
            locator.Kind,
            capabilities,
            metadata: DescriptorMetadata(descriptor));
    }

    private KubeNavigationNode MaterializeResource(KubeResource value, KubeResourceDescriptor descriptor)
    {
        KubeNamespaceScope scope = descriptor.Namespaced
            ? KubeNamespaceScope.Explicit(value.Identity.Namespace ?? throw new KubeException(KubeErrorKind.Serialization, "Namespaced resource has no namespace.", resource: value.Identity, target: Target))
            : KubeNamespaceScope.Cluster;
        ResourceItemLocator locator = new(TargetRoot.TargetKey, GroupResource.From(descriptor.Gvr), scope, value.Identity.Name);
        KubeNavigationCapabilities capabilities = KubeNavigationCapabilities.Readable;
        if (descriptor.Verbs.Contains("patch")) capabilities |= KubeNavigationCapabilities.Editable;
        if (descriptor.Verbs.Contains("delete")) capabilities |= KubeNavigationCapabilities.Deletable;
        Dictionary<string, object?> metadata = new(DescriptorMetadata(descriptor))
        {
            ["Namespace"] = value.Identity.Namespace,
            ["Kind"] = value.Identity.Kind ?? descriptor.Kind,
            ["ApiVersion"] = value.Identity.ApiVersion,
            ["ResourceVersion"] = value.ResourceVersion,
            ["Uid"] = value.Document["metadata"]?["uid"]?.GetValue<string>()
        };
        return new KubeNavigationNode(locator, value.Identity.Name, value.Identity.Name, locator.Kind, capabilities, value, metadata);
    }

    private KubeExecutionResult<KubeNavigationNode> ProjectResult(KubeExecutionResult<KubeResource> result, KubeResourceDescriptor descriptor) =>
        new(MaterializeResource(result.Value, descriptor), result.Warnings, result.Diagnostics);

    private static ResourceIdentity BuildIdentity(ResourceItemLocator locator, KubeResourceDescriptor descriptor)
    {
        EnsureScopeCompatible(locator.Scope, descriptor);
        return new ResourceIdentity(descriptor.Gvr, locator.Name, locator.Scope, kind: descriptor.Kind);
    }

    private static Dictionary<string, object?> DescriptorMetadata(KubeResourceDescriptor descriptor) => new()
    {
        ["GroupResource"] = GroupResource.From(descriptor.Gvr).ToString(),
        ["ApiVersion"] = descriptor.Gvr.ApiVersion,
        ["Kind"] = descriptor.Kind,
        ["Namespaced"] = descriptor.Namespaced
    };

    private static bool SameResource(GroupResource left, GroupResource right) =>
        string.Equals(left.Group, right.Group, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.Resource, right.Resource, StringComparison.OrdinalIgnoreCase);

    private static void EnsureScopeCompatible(KubeNamespaceScope scope, KubeResourceDescriptor descriptor)
    {
        if (descriptor.Namespaced && scope.Kind is KubeNamespaceScopeKind.Cluster)
            throw InvalidMount($"Namespaced resource '{GroupResource.From(descriptor.Gvr)}' cannot use cluster scope.");
        if (!descriptor.Namespaced && scope.Kind is not KubeNamespaceScopeKind.Cluster)
            throw InvalidMount($"Cluster-scoped resource '{GroupResource.From(descriptor.Gvr)}' cannot use namespace scope.");
    }

    private static KubeException InvalidMount(string message) =>
        new(KubeErrorKind.InvalidResource, message, code: "navigation.invalid-mount");

    private bool IsTopologyCacheable(KubeNodeLocator locator) =>
        locator is TargetRootLocator or NamespaceLocator or ClusterRootLocator;

    private void ValidateTarget(KubeNodeLocator locator)
    {
        ArgumentNullException.ThrowIfNull(locator);
        if (!string.Equals(locator.TargetKey, TargetRoot.TargetKey, StringComparison.Ordinal))
            throw new ArgumentException("The locator belongs to a different Kubernetes target.", nameof(locator));
    }
}
