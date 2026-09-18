using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;

namespace KubeShell.Runtime;

/// <summary>Version-neutral Kubernetes group/resource identity used by long-lived navigation and UI state.</summary>
public readonly record struct GroupResource(string Group, string Resource)
{
    public static GroupResource From(GroupVersionResource gvr) => new(gvr.Group ?? string.Empty, gvr.Resource);

    public override string ToString() =>
        string.IsNullOrWhiteSpace(Group) ? Resource : $"{Resource}.{Group}";
}

/// <summary>Kubernetes group/version/resource address. An empty Version means discovery is still required.</summary>
public readonly record struct GroupVersionResource(string Group, string Version, string Resource)
{
    public bool IsResolved => !string.IsNullOrWhiteSpace(Version) && !string.IsNullOrWhiteSpace(Resource);
    public string ApiVersion => string.IsNullOrWhiteSpace(Group) ? Version : $"{Group}/{Version}";

    public static GroupVersionResource FromLegacy(string resource, string? apiVersion = null)
    {
        if (string.IsNullOrWhiteSpace(resource)) throw new ArgumentException("Resource is required.", nameof(resource));
        string token = resource.Trim();
        string group = string.Empty;
        string version = string.Empty;
        if (!string.IsNullOrWhiteSpace(apiVersion))
        {
            string[] parts = apiVersion.Split('/', 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 1) version = parts[0];
            else { group = parts[0]; version = parts[1]; }
        }

        int dot = token.IndexOf('.');
        if (dot > 0)
        {
            string resourcePart = token[..dot];
            string groupPart = token[(dot + 1)..];
            if (string.IsNullOrWhiteSpace(group)) group = groupPart;
            token = resourcePart;
        }
        return new GroupVersionResource(group, version, token);
    }

    public override string ToString() =>
        string.IsNullOrWhiteSpace(Group)
            ? (string.IsNullOrWhiteSpace(Version) ? Resource : $"{Version}/{Resource}")
            : (string.IsNullOrWhiteSpace(Version) ? $"{Resource}.{Group}" : $"{Group}/{Version}/{Resource}");
}

public enum KubeNamespaceScopeKind
{
    Default,
    Explicit,
    All,
    Cluster
}

public sealed record KubeNamespaceScope
{
    private KubeNamespaceScope(KubeNamespaceScopeKind kind, string? name)
    {
        if (kind == KubeNamespaceScopeKind.Explicit && string.IsNullOrWhiteSpace(name))
            throw new ArgumentException("Explicit namespace scope requires a namespace name.", nameof(name));
        Kind = kind;
        Name = string.IsNullOrWhiteSpace(name) ? null : name;
    }

    public KubeNamespaceScopeKind Kind { get; }
    public string? Name { get; }

    public static KubeNamespaceScope Default { get; } = new(KubeNamespaceScopeKind.Default, null);
    public static KubeNamespaceScope All { get; } = new(KubeNamespaceScopeKind.All, null);
    public static KubeNamespaceScope Cluster { get; } = new(KubeNamespaceScopeKind.Cluster, null);
    public static KubeNamespaceScope Explicit(string name) => new(KubeNamespaceScopeKind.Explicit, name);

    public string? Resolve(KubeTarget target) => Kind switch
    {
        KubeNamespaceScopeKind.Explicit => Name,
        KubeNamespaceScopeKind.Default => target.DefaultNamespace,
        _ => null
    };
}

public sealed record ResourceIdentity
{
    public ResourceIdentity(GroupVersionResource gvr, string name, KubeNamespaceScope? namespaceScope = null, string? subresource = null, string? kind = null)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Resource name is required.", nameof(name));
        KubeNamespaceScope effectiveScope = namespaceScope ?? KubeNamespaceScope.Default;
        if (effectiveScope.Kind == KubeNamespaceScopeKind.All)
            throw new ArgumentException("A single Kubernetes resource identity cannot use all-namespaces scope. Resolve the concrete namespace first.", nameof(namespaceScope));
        Gvr = gvr;
        Name = name;
        NamespaceScope = effectiveScope;
        Subresource = string.IsNullOrWhiteSpace(subresource) ? null : subresource;
        Kind = string.IsNullOrWhiteSpace(kind) ? null : kind;
    }

    public ResourceIdentity(GroupVersionResource gvr, string name, string? @namespace, string? subresource = null, string? kind = null)
        : this(gvr, name, !string.IsNullOrWhiteSpace(@namespace) ? KubeNamespaceScope.Explicit(@namespace) : KubeNamespaceScope.Default, subresource, kind) { }

    // Transitional constructor for the script module. Internally the identity is GVR-first.
    public ResourceIdentity(string resource, string name, string? @namespace = null, string? kind = null, string? apiVersion = null)
        : this(GroupVersionResource.FromLegacy(resource, apiVersion), name, @namespace, null, kind) { }

    public GroupVersionResource Gvr { get; }
    public string Name { get; }
    public KubeNamespaceScope NamespaceScope { get; }
    public string? Namespace => NamespaceScope.Kind == KubeNamespaceScopeKind.Explicit ? NamespaceScope.Name : null;
    public string? Subresource { get; }
    public string? Kind { get; }
    public string Resource => Gvr.Resource;
    public string? ApiVersion => string.IsNullOrWhiteSpace(Gvr.Version) ? null : Gvr.ApiVersion;
}

public sealed record ResourceQuery
{
    public ResourceQuery(
        GroupVersionResource gvr,
        string? name = null,
        KubeNamespaceScope? namespaceScope = null,
        string? labelSelector = null,
        string? fieldSelector = null,
        string? subresource = null)
    {
        Gvr = gvr;
        Name = string.IsNullOrWhiteSpace(name) ? null : name;
        NamespaceScope = namespaceScope ?? KubeNamespaceScope.Default;
        LabelSelector = string.IsNullOrWhiteSpace(labelSelector) ? null : labelSelector;
        FieldSelector = string.IsNullOrWhiteSpace(fieldSelector) ? null : fieldSelector;
        Subresource = string.IsNullOrWhiteSpace(subresource) ? null : subresource;
    }

    // Transitional constructor used by the existing PowerShell frontend.
    public ResourceQuery(
        string resource,
        string? name = null,
        string? @namespace = null,
        bool allNamespaces = false,
        string? labelSelector = null,
        string? fieldSelector = null,
        string? apiVersion = null)
        : this(
            GroupVersionResource.FromLegacy(resource, apiVersion),
            name,
            allNamespaces ? KubeNamespaceScope.All : (!string.IsNullOrWhiteSpace(@namespace) ? KubeNamespaceScope.Explicit(@namespace) : KubeNamespaceScope.Default),
            labelSelector,
            fieldSelector) { }

    public GroupVersionResource Gvr { get; }
    public string? Name { get; }
    public KubeNamespaceScope NamespaceScope { get; }
    public string? LabelSelector { get; }
    public string? FieldSelector { get; }
    public string? Subresource { get; }

    public string Resource => Gvr.Resource;
    public string? ApiVersion => string.IsNullOrWhiteSpace(Gvr.Version) ? null : Gvr.ApiVersion;
    public string? Namespace => NamespaceScope.Kind == KubeNamespaceScopeKind.Explicit ? NamespaceScope.Name : null;
    public bool AllNamespaces => NamespaceScope.Kind == KubeNamespaceScopeKind.All;

    public ResourceIdentity ToIdentity(KubeTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (string.IsNullOrWhiteSpace(Name)) throw new InvalidOperationException("A named query is required to form a resource identity.");
        if (NamespaceScope.Kind == KubeNamespaceScopeKind.All)
            throw new InvalidOperationException("An all-namespaces query cannot form a single resource identity. Resolve the concrete namespace first.");
        return new ResourceIdentity(Gvr, Name, NamespaceScope, Subresource);
    }
}

public sealed record KubeSubresourceDescriptor
{
    public KubeSubresourceDescriptor(
        string name,
        string? group,
        string? version,
        string? kind,
        bool namespaced,
        IEnumerable<string>? verbs = null)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Subresource name is required.", nameof(name));
        Name = name;
        Group = string.IsNullOrWhiteSpace(group) ? null : group;
        Version = string.IsNullOrWhiteSpace(version) ? null : version;
        Kind = string.IsNullOrWhiteSpace(kind) ? null : kind;
        Namespaced = namespaced;
        Verbs = new HashSet<string>(verbs ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
    }

    public string Name { get; }
    public string? Group { get; }
    public string? Version { get; }
    public string? Kind { get; }
    public bool Namespaced { get; }
    public IReadOnlySet<string> Verbs { get; }
}

public sealed record KubeResourceDescriptor(
    GroupVersionResource Gvr,
    string? Kind,
    bool Namespaced,
    IReadOnlySet<string> Verbs,
    IReadOnlySet<string> Subresources)
{
    public string? SingularName { get; init; }
    public IReadOnlySet<string> ShortNames { get; init; } = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    public IReadOnlySet<string> Categories { get; init; } = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    public IReadOnlyDictionary<string, KubeSubresourceDescriptor> SubresourceDetails { get; init; } =
        new Dictionary<string, KubeSubresourceDescriptor>(StringComparer.OrdinalIgnoreCase);

    public bool MatchesResourceToken(string token) =>
        string.Equals(Gvr.Resource, token, StringComparison.OrdinalIgnoreCase) ||
        (!string.IsNullOrWhiteSpace(SingularName) && string.Equals(SingularName, token, StringComparison.OrdinalIgnoreCase)) ||
        (!string.IsNullOrWhiteSpace(Kind) && string.Equals(Kind, token, StringComparison.OrdinalIgnoreCase)) ||
        ShortNames.Contains(token);

    public static KubeResourceDescriptor Create(
        GroupVersionResource gvr,
        string? kind,
        bool namespaced,
        IEnumerable<string>? verbs = null,
        IEnumerable<string>? subresources = null,
        string? singularName = null,
        IEnumerable<string>? shortNames = null,
        IEnumerable<string>? categories = null,
        IEnumerable<KubeSubresourceDescriptor>? subresourceDetails = null)
    {
        Dictionary<string, KubeSubresourceDescriptor> details = (subresourceDetails ?? Array.Empty<KubeSubresourceDescriptor>())
            .GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.First(), StringComparer.OrdinalIgnoreCase);
        HashSet<string> names = new(subresources ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
        names.UnionWith(details.Keys);
        return new KubeResourceDescriptor(
            gvr,
            string.IsNullOrWhiteSpace(kind) ? null : kind,
            namespaced,
            new HashSet<string>(verbs ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase),
            names)
        {
            SingularName = string.IsNullOrWhiteSpace(singularName) ? null : singularName,
            ShortNames = new HashSet<string>(shortNames ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase),
            Categories = new HashSet<string>(categories ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase),
            SubresourceDetails = details
        };
    }
}

public sealed class KubeResource
{
    private readonly JsonObject _document;

    public KubeResource(ResourceIdentity identity, JsonObject document)
    {
        Identity = identity ?? throw new ArgumentNullException(nameof(identity));
        ArgumentNullException.ThrowIfNull(document);

        // A resource identity and its document form one value at the Runtime boundary. Keep an owned
        // snapshot so callers cannot mutate metadata after construction and invalidate that pairing.
        _document = (JsonObject)document.DeepClone();
    }

    public ResourceIdentity Identity { get; }

    /// <summary>
    /// Returns a defensive copy. Mutation is intentionally local to the caller; a changed document
    /// becomes a new KubeResource after validation rather than mutating this value in place.
    /// </summary>
    public JsonObject Document => (JsonObject)_document.DeepClone();
    public string RawJson => _document.ToJsonString(KubeJson.Options);
    public string? ResourceVersion => _document["metadata"]?["resourceVersion"]?.GetValue<string>();

    public static KubeResource FromDocument(GroupVersionResource gvr, JsonObject document)
    {
        string? name = document["metadata"]?["name"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(name))
            throw new KubeException(KubeErrorKind.Serialization, "Kubernetes resource JSON has no metadata.name.");

        string? ns = document["metadata"]?["namespace"]?.GetValue<string>();
        string? kind = document["kind"]?.GetValue<string>();
        string? apiVersion = document["apiVersion"]?.GetValue<string>();
        GroupVersionResource effective = gvr.IsResolved ? gvr : GroupVersionResource.FromLegacy(gvr.Resource, apiVersion);
        KubeNamespaceScope scope = string.IsNullOrWhiteSpace(ns)
            ? KubeNamespaceScope.Cluster
            : KubeNamespaceScope.Explicit(ns);
        return new KubeResource(new ResourceIdentity(effective, name, scope, kind: kind), document);
    }

    public static KubeResource FromDocument(string resource, JsonObject document) =>
        FromDocument(GroupVersionResource.FromLegacy(resource, document["apiVersion"]?.GetValue<string>()), document);
}
