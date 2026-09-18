using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Security.Cryptography;
using System.Text;
using KubeShell.Runtime;

namespace KubeShell.ObjectModel;

public enum KubeNavigationNodeKind
{
    TargetRoot,
    NamespacesRoot,
    Namespace,
    ClusterRoot,
    ResourceCollection,
    ResourceNamespaceBucket,
    ResourceItem
}

[Flags]
public enum KubeNavigationCapabilities
{
    None = 0,
    Container = 1,
    Readable = 2,
    Creatable = 4,
    Editable = 8,
    Deletable = 16,
    Refreshable = 32
}

/// <summary>Version-neutral semantic location. It is intentionally independent of any frontend path syntax.</summary>
public abstract record KubeNodeLocator(string TargetKey)
{
    public abstract KubeNavigationNodeKind Kind { get; }
    public abstract string SemanticPath { get; }
    public string StableId => $"kube:{TargetKey}:{SemanticPath}";
}

public sealed record TargetRootLocator(string Target) : KubeNodeLocator(Target)
{
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.TargetRoot;
    public override string SemanticPath => "target";
}

public sealed record NamespacesRootLocator(string Target) : KubeNodeLocator(Target)
{
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.NamespacesRoot;
    public override string SemanticPath => "namespaces";
}

public sealed record NamespaceLocator(string Target, string Namespace) : KubeNodeLocator(Target)
{
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.Namespace;
    public override string SemanticPath => $"namespace/{Escape(Namespace)}";
    private static string Escape(string value) => Uri.EscapeDataString(value);
}

public sealed record ClusterRootLocator(string Target) : KubeNodeLocator(Target)
{
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.ClusterRoot;
    public override string SemanticPath => "cluster";
}

public sealed record ResourceCollectionLocator : KubeNodeLocator
{
    public ResourceCollectionLocator(string target, GroupResource resource, KubeNamespaceScope scope)
        : base(target)
    {
        ValidateResource(resource);
        Scope = scope ?? throw new ArgumentNullException(nameof(scope));
        if (scope.Kind == KubeNamespaceScopeKind.Default)
            throw new ArgumentException("Navigation collection scope must be cluster, all namespaces, or an explicit namespace.", nameof(scope));
        Resource = resource;
    }

    public GroupResource Resource { get; }
    public KubeNamespaceScope Scope { get; }
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.ResourceCollection;
    public override string SemanticPath => $"collection/{Escape(Resource.ToString())}/{ScopeToken(Scope)}";

    internal static string ScopeToken(KubeNamespaceScope scope) => scope.Kind switch
    {
        KubeNamespaceScopeKind.Cluster => "cluster",
        KubeNamespaceScopeKind.All => "all",
        KubeNamespaceScopeKind.Explicit => $"ns/{Escape(scope.Name ?? string.Empty)}",
        _ => throw new ArgumentException("Navigation scope must already be concrete.", nameof(scope))
    };

    internal static void ValidateResource(GroupResource resource)
    {
        if (string.IsNullOrWhiteSpace(resource.Resource))
            throw new ArgumentException("Resource name is required.", nameof(resource));
    }

    private static string Escape(string value) => Uri.EscapeDataString(value);
}

public sealed record ResourceNamespaceBucketLocator : KubeNodeLocator
{
    public ResourceNamespaceBucketLocator(string target, GroupResource resource, string @namespace)
        : base(target)
    {
        ResourceCollectionLocator.ValidateResource(resource);
        if (string.IsNullOrWhiteSpace(@namespace))
            throw new ArgumentException("Namespace bucket requires an explicit namespace.", nameof(@namespace));
        Resource = resource;
        Namespace = @namespace;
    }

    public GroupResource Resource { get; }
    public string Namespace { get; }
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.ResourceNamespaceBucket;
    public override string SemanticPath => $"bucket/{Uri.EscapeDataString(Resource.ToString())}/{Uri.EscapeDataString(Namespace)}";
}

public sealed record ResourceItemLocator : KubeNodeLocator
{
    public ResourceItemLocator(string target, GroupResource resource, KubeNamespaceScope scope, string name)
        : base(target)
    {
        ResourceCollectionLocator.ValidateResource(resource);
        Scope = scope ?? throw new ArgumentNullException(nameof(scope));
        if (scope.Kind is KubeNamespaceScopeKind.Default or KubeNamespaceScopeKind.All)
            throw new ArgumentException("A navigation item must use cluster scope or an explicit namespace.", nameof(scope));
        if (string.IsNullOrWhiteSpace(name))
            throw new ArgumentException("Resource item name is required.", nameof(name));
        Resource = resource;
        Name = name;
    }

    public GroupResource Resource { get; }
    public KubeNamespaceScope Scope { get; }
    public string Name { get; }
    public override KubeNavigationNodeKind Kind => KubeNavigationNodeKind.ResourceItem;
    public override string SemanticPath => $"item/{Uri.EscapeDataString(Resource.ToString())}/{ResourceCollectionLocator.ScopeToken(Scope)}/{Uri.EscapeDataString(Name)}";
}

public sealed class KubeNavigationNode
{
    public KubeNavigationNode(
        KubeNodeLocator locator,
        string name,
        string displayName,
        KubeNavigationNodeKind kind,
        KubeNavigationCapabilities capabilities,
        KubeResource? value = null,
        IReadOnlyDictionary<string, object?>? metadata = null)
    {
        Locator = locator ?? throw new ArgumentNullException(nameof(locator));
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Node name is required.", nameof(name));
        Name = name;
        DisplayName = string.IsNullOrWhiteSpace(displayName) ? name : displayName;
        Kind = kind;
        Capabilities = capabilities;
        Value = value;

        Dictionary<string, object?> snapshot = metadata is null
            ? new Dictionary<string, object?>()
            : new Dictionary<string, object?>(metadata, StringComparer.Ordinal);
        Properties = new ReadOnlyDictionary<string, object?>(snapshot);
    }

    public string Id => Locator.StableId;
    public KubeNodeLocator Locator { get; }
    public string Name { get; }
    public string DisplayName { get; }
    public KubeNavigationNodeKind Kind { get; }
    public KubeNavigationCapabilities Capabilities { get; }
    public KubeResource? Value { get; }
    public IReadOnlyDictionary<string, object?> Properties { get; }
    public bool IsContainer => (Capabilities & KubeNavigationCapabilities.Container) != 0;
}

public sealed record KubeMountRequest(
    string? Namespace = null,
    string? Resource = null,
    bool AllNamespaces = false);

public static class KubeTargetIdentity
{
    /// <summary>Stable, non-display identity for cache keys and selection persistence.</summary>
    public static string Create(KubeTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        // Stable target identity describes execution identity, not how a frontend named or
        // mounted it. Profile/config-set/source/default-namespace are presentation or defaults;
        // explicit navigation locators already carry namespace scope.
        string material = KubeTargetIdentityEncoding.Create(target);
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(material));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
