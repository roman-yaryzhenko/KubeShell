using System;
using System.Collections.Generic;
using System.Linq;

namespace KubeShell.Runtime;

/// <summary>
/// Immutable representation of a named kubeconfig set.
/// Persistence deliberately lives outside Runtime: this type describes policy data, not where it is stored.
/// </summary>
public sealed class KubeConfigSet
{
    private readonly string[] _paths;

    public KubeConfigSet(string name, IEnumerable<string>? paths)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Config-set name cannot be empty.", nameof(name));
        Name = name;
        List<string> exactPaths = new();
        foreach (string? path in paths ?? Array.Empty<string>())
        {
            if (path is null) throw new ArgumentException("Kubeconfig path cannot be null.", nameof(paths));
            if (path.Length == 0) throw new ArgumentException("Kubeconfig path cannot be empty.", nameof(paths));
            exactPaths.Add(path);
        }
        _paths = exactPaths.ToArray();
    }

    public string Name { get; }
    public IReadOnlyList<string> Paths => Array.AsReadOnly(_paths);

    public KubeConfigSet WithPaths(IEnumerable<string>? paths) => new(Name, paths);
}

/// <summary>Immutable user-facing target profile representation.</summary>
public sealed class KubeProfile
{
    public KubeProfile(string name, string? configSet, string? context = null, string? @namespace = null)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Profile name cannot be empty.", nameof(name));
        Name = name;
        ConfigSet = configSet ?? string.Empty;
        Context = string.IsNullOrEmpty(context) ? null : context;
        Namespace = string.IsNullOrWhiteSpace(@namespace) ? null : @namespace;
    }

    public string Name { get; }
    public string ConfigSet { get; }
    public string? Context { get; }
    public string? Namespace { get; }

}

/// <summary>
/// In-memory configuration document. File-system paths, environment-variable lookup and JSON persistence
/// are adapter concerns and intentionally do not belong to KubeShell.Runtime.
/// </summary>
public sealed class KubeConfigurationDocument
{
    public KubeConfigurationDocument(
        int version,
        IEnumerable<KubeConfigSet>? configSets = null,
        IEnumerable<KubeProfile>? profiles = null)
    {
        Version = version;
        ConfigSets = Array.AsReadOnly((configSets ?? Array.Empty<KubeConfigSet>()).ToArray());
        Profiles = Array.AsReadOnly((profiles ?? Array.Empty<KubeProfile>()).ToArray());
    }

    public int Version { get; }
    public IReadOnlyList<KubeConfigSet> ConfigSets { get; }
    public IReadOnlyList<KubeProfile> Profiles { get; }
}

/// <summary>
/// Resolves already-loaded configuration data into a fully specified Runtime target.
/// Loading the document is deliberately injected by the caller so Runtime has no file-system dependency.
/// </summary>
public sealed class KubeTargetResolver
{
    private readonly KubeConfigurationDocument _configuration;

    public KubeTargetResolver(KubeConfigurationDocument configuration)
    {
        _configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
    }

    public KubeTarget ResolveReference(string reference)
    {
        if (string.IsNullOrEmpty(reference))
            throw new KubeException(KubeErrorKind.Configuration, "KubeShell target reference cannot be empty.");

        if (reference.StartsWith("profile:", StringComparison.OrdinalIgnoreCase))
        {
            string profileName = reference["profile:".Length..];
            KubeProfile profile = FindProfile(profileName);
            KubeConfigSet configSet = FindConfigSet(profile.ConfigSet);
            return new KubeTarget(
                profile.Context,
                configSet.Paths,
                profile.Namespace,
                profile.Name,
                configSet.Name,
                reference);
        }

        if (reference.StartsWith("configset:", StringComparison.OrdinalIgnoreCase))
        {
            string configSetName = reference["configset:".Length..];
            KubeConfigSet configSet = FindConfigSet(configSetName);
            return new KubeTarget(null, configSet.Paths, null, null, configSet.Name, reference);
        }

        return new KubeTarget(reference, Array.Empty<string>(), null, null, null, reference);
    }

    private KubeConfigSet FindConfigSet(string name) =>
        _configuration.ConfigSets.FirstOrDefault(item => string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase))
        ?? throw new KubeException(KubeErrorKind.Configuration, "KubeShell configSets entry '" + name + "' was not found.");

    private KubeProfile FindProfile(string name) =>
        _configuration.Profiles.FirstOrDefault(item => string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase))
        ?? throw new KubeException(KubeErrorKind.Configuration, "KubeShell profiles entry '" + name + "' was not found.");
}

/// <summary>
/// Pure target-freezing policy used by outer adapters when a profile/config-set intentionally
/// refers to the kubeconfig current-context. File loading and backend I/O remain outside Runtime.
/// </summary>
public static class KubeTargetResolution
{
    public static KubeTarget FreezeCurrentContext(KubeTarget target, KubeConfigView view)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(view);
        if (!string.IsNullOrEmpty(target.Context)) return target;

        string? context = view.CurrentContext;
        if (string.IsNullOrEmpty(context))
            throw new KubeException(KubeErrorKind.Configuration, $"No current Kubernetes context could be resolved for '{target.Source}'.", target: target);
        if (!view.Contexts.Any(item => string.Equals(item.Name, context, StringComparison.Ordinal)))
            throw new KubeException(KubeErrorKind.Configuration, $"Kubernetes context '{context}' was not found for '{target.Source}'.", target: target);

        return new KubeTarget(context, target.KubeConfigPaths, target.DefaultNamespace, target.Profile, target.ConfigSet, target.Source);
    }
}
