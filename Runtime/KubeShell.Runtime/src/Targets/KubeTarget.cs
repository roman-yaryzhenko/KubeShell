using System;
using System.Collections.Generic;
using System.Linq;

namespace KubeShell.Runtime;

/// <summary>Immutable description of the Kubernetes target selected by the frontend.</summary>
public sealed class KubeTarget
{
    private readonly string[] _kubeConfigPaths;

    public KubeTarget(
        string? context = null,
        IEnumerable<string>? kubeConfigPaths = null,
        string? @namespace = null,
        string? profile = null,
        string? configSet = null,
        string source = "Default")
    {
        Context = NullIfEmpty(context);
        _kubeConfigPaths = PreserveKubeConfigPaths(kubeConfigPaths);
        DefaultNamespace = NullIfWhiteSpace(@namespace);
        Profile = NullIfWhiteSpace(profile);
        ConfigSet = NullIfWhiteSpace(configSet);
        Source = string.IsNullOrWhiteSpace(source) ? "Default" : source;
    }

    public string? Context { get; }
    public string[] KubeConfigPaths => (string[])_kubeConfigPaths.Clone();
    public string? DefaultNamespace { get; }
    public string? Namespace => DefaultNamespace; // compatibility/readability for PowerShell frontends
    public string? Profile { get; }
    public string? ConfigSet { get; }
    public string Source { get; }

    private static string[] PreserveKubeConfigPaths(IEnumerable<string>? paths)
    {
        List<string> result = new();
        foreach (string? path in paths ?? Array.Empty<string>())
        {
            if (path is null) throw new ArgumentException("Kubeconfig path cannot be null.", nameof(paths));
            if (path.Length == 0) throw new ArgumentException("Kubeconfig path cannot be empty.", nameof(paths));
            result.Add(path);
        }
        return result.ToArray();
    }

    private static string? NullIfEmpty(string? value) =>
        string.IsNullOrEmpty(value) ? null : value;

    private static string? NullIfWhiteSpace(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;
}
