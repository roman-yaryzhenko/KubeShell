using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography.X509Certificates;
using k8s;
using k8s.KubeConfigModels;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

/// <summary>
/// Owns KubernetesClient session/configuration creation. Keeping kubeconfig IO and SDK construction
/// here prevents those framework details from leaking into Runtime or operation policy.
/// </summary>
internal sealed class KubernetesSessionFactory
{
    private readonly KubernetesClientConfiguration? _explicitConfiguration;

    public KubernetesSessionFactory(KubernetesClientConfiguration? explicitConfiguration = null)
    {
        _explicitConfiguration = explicitConfiguration;
    }

    public static KubernetesClientConfiguration CreateExplicitConfiguration(
        Uri server,
        string? bearerToken = null,
        X509Certificate2? clientCertificate = null,
        X509Certificate2? certificateAuthority = null,
        bool skipCertificateCheck = false,
        string? defaultNamespace = null)
    {
        ArgumentNullException.ThrowIfNull(server);
        KubernetesClientConfiguration config = new()
        {
            Host = server.AbsoluteUri,
            AccessToken = string.IsNullOrWhiteSpace(bearerToken) ? null : bearerToken,
            SkipTlsVerify = skipCertificateCheck,
            Namespace = string.IsNullOrWhiteSpace(defaultNamespace) ? "default" : defaultNamespace,
            UserAgent = "KubeShell/0.3.0"
        };
        if (certificateAuthority is not null)
        {
            config.SslCaCerts = new X509Certificate2Collection();
            config.SslCaCerts.Add(certificateAuthority);
        }
        if (clientCertificate is not null)
        {
            config.FirstMessageHandlerSetup = handler =>
            {
                handler.SslOptions.ClientCertificates ??= new X509Certificate2Collection();
                handler.SslOptions.ClientCertificates.Add(clientCertificate);
            };
        }
        return config;
    }

    public ManagedSession Create(KubeTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubernetesClientConfiguration config;
        if (_explicitConfiguration is not null)
        {
            config = _explicitConfiguration;
            return new ManagedSession(config, new Kubernetes(config));
        }

        if (target.KubeConfigPaths.Length == 0)
            throw new KubeException(
                KubeErrorKind.Configuration,
                "The managed backend requires explicit kubeconfig path(s) in KubeTarget.",
                target: target,
                code: "managed.target.kubeconfig");

        K8SConfiguration merged = LoadMerged(target.KubeConfigPaths);
        config = KubernetesClientConfiguration.BuildConfigFromConfigObject(merged, target.Context);

        return new ManagedSession(config, new Kubernetes(config));
    }

    public string GetDiscoveryCacheIdentity(KubeTarget target, KubeExecutionContext executionContext)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);
        string endpoint = _explicitConfiguration?.Host ?? string.Empty;
        return KubeTargetIdentityEncoding.EncodeFields(new string?[]
        {
            endpoint,
            KubeTargetIdentityEncoding.Create(target),
            SecurityIdentity(executionContext)
        });
    }

    private static string SecurityIdentity(KubeExecutionContext executionContext)
    {
        KubeImpersonation? impersonation = executionContext.Impersonation;
        if (impersonation is null) return string.Empty;

        List<string?> fields = new()
        {
            "user", impersonation.User,
            "uid", impersonation.Uid,
            "groups", KubeTargetIdentityEncoding.EncodeFields(impersonation.EffectiveGroups.OrderBy(x => x, StringComparer.Ordinal))
        };
        foreach (KeyValuePair<string, IReadOnlyList<string>> entry in impersonation.EffectiveExtra.OrderBy(x => x.Key, StringComparer.Ordinal))
        {
            fields.Add("extra");
            fields.Add(entry.Key);
            fields.Add(KubeTargetIdentityEncoding.EncodeFields(entry.Value.OrderBy(v => v, StringComparer.Ordinal)));
        }
        return KubeTargetIdentityEncoding.EncodeFields(fields);
    }

    // KubernetesClient has equivalent multi-file behavior internally, but it is not exposed as a
    // reusable public helper. Preserve first-occurrence-wins semantics without mutating KUBECONFIG.
    private static K8SConfiguration LoadMerged(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) throw new ArgumentException("At least one kubeconfig path is required.", nameof(paths));
        K8SConfiguration baseConfig = KubernetesClientConfiguration.LoadKubeConfig(paths[0]);
        for (int i = 1; i < paths.Count; i++) Merge(baseConfig, KubernetesClientConfiguration.LoadKubeConfig(paths[i]));
        return baseConfig;
    }

    private static void Merge(K8SConfiguration target, K8SConfiguration incoming)
    {
        target.CurrentContext ??= incoming.CurrentContext;
        target.FileName ??= incoming.FileName;
        if (!string.Equals(target.Kind, incoming.Kind, StringComparison.Ordinal))
            throw new KubeException(KubeErrorKind.Configuration, $"kubeconfig kinds differ between '{target.FileName}' and '{incoming.FileName}'.");
        if (incoming.Preferences is not null && target.Preferences is not null)
        {
            foreach (KeyValuePair<string, object> preference in incoming.Preferences)
                if (!target.Preferences.ContainsKey(preference.Key)) target.Preferences[preference.Key] = preference.Value;
        }
        target.Extensions = MergeByName(target.Extensions, incoming.Extensions, x => x.Name);
        target.Clusters = MergeByName(target.Clusters, incoming.Clusters, x => x.Name);
        target.Users = MergeByName(target.Users, incoming.Users, x => x.Name);
        target.Contexts = MergeByName(target.Contexts, incoming.Contexts, x => x.Name);
    }

    private static IEnumerable<T> MergeByName<T>(IEnumerable<T>? first, IEnumerable<T>? second, Func<T, string> name)
    {
        Dictionary<string, T> map = new(StringComparer.Ordinal);
        foreach (T item in first ?? Array.Empty<T>()) map[name(item)] = item;
        foreach (T item in second ?? Array.Empty<T>()) if (!map.ContainsKey(name(item))) map[name(item)] = item;
        return map.Values;
    }
}

internal sealed class ManagedSession : IDisposable
{
    public ManagedSession(KubernetesClientConfiguration configuration, IKubernetes client)
    {
        Configuration = configuration;
        Client = client;
    }

    public KubernetesClientConfiguration Configuration { get; }
    public IKubernetes Client { get; }
    public void Dispose() => Client.Dispose();
}
