using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using k8s.Autorest;
using k8s.Models;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

/// <summary>Owns API discovery and its cache; resource/navigation caches are intentionally separate concerns.</summary>
internal sealed class KubernetesDiscoveryService
{
    private readonly KubernetesSessionFactory _sessions;
    private readonly ConcurrentDictionary<string, IReadOnlyList<KubeResourceDescriptor>> _cache = new(StringComparer.Ordinal);

    public KubernetesDiscoveryService(KubernetesSessionFactory sessions)
    {
        _sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
    }

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        TranslateAsync(
            () => GetPreferredResourcesCoreAsync(target, executionContext, refresh, cancellationToken),
            target);

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        TranslateAsync(
            () => GetApiVersionResourcesCoreAsync(apiVersion, target, executionContext, refresh, cancellationToken),
            target);

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        GroupVersionResource resource,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        TranslateAsync(
            () => ResolveResourceCoreAsync(resource, target, executionContext, refresh, cancellationToken),
            target);

    private async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesCoreAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        string cacheKey = $"{_sessions.GetDiscoveryCacheIdentity(target, executionContext)}|preferred";
        if (!refresh && _cache.TryGetValue(cacheKey, out IReadOnlyList<KubeResourceDescriptor>? cached)) return cached;

        using CancellationTokenSource? timeout = KubernetesRequestContext.CreateTimeoutSource(executionContext.Timeout, cancellationToken);
        CancellationToken effectiveToken = timeout?.Token ?? cancellationToken;
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers = KubernetesRequestContext.BuildHeaders(executionContext);

        using ManagedSession session = _sessions.Create(target);
        using HttpOperationResponse<V1APIVersions> coreResponse = await session.Client.Core.GetAPIVersionsWithHttpMessagesAsync(
            customHeaders: headers, cancellationToken: effectiveToken).ConfigureAwait(false);
        using HttpOperationResponse<V1APIGroupList> groupResponse = await session.Client.Apis.GetAPIVersionsWithHttpMessagesAsync(
            customHeaders: headers, cancellationToken: effectiveToken).ConfigureAwait(false);

        List<string> preferredVersions = new();
        string? coreVersion = coreResponse.Body.Versions?.FirstOrDefault(x => string.Equals(x, "v1", StringComparison.Ordinal))
            ?? coreResponse.Body.Versions?.FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(coreVersion)) preferredVersions.Add(coreVersion);

        foreach (V1APIGroup group in groupResponse.Body.Groups ?? Array.Empty<V1APIGroup>())
        {
            string? groupVersion = group.PreferredVersion?.GroupVersion;
            if (!string.IsNullOrWhiteSpace(groupVersion)) preferredVersions.Add(groupVersion);
        }

        List<KubeResourceDescriptor> result = new();
        HttpOperationException? firstPartialFailure = null;
        foreach (string apiVersion in preferredVersions.Distinct(StringComparer.Ordinal))
        {
            try
            {
                IReadOnlyList<KubeResourceDescriptor> resources = await GetApiVersionResourcesCoreAsync(
                    apiVersion, target, executionContext, refresh, effectiveToken).ConfigureAwait(false);
                result.AddRange(resources);
            }
            catch (HttpOperationException ex)
            {
                // Kubernetes aggregated discovery can be partially available. Match the native
                // backend: keep useful preferred descriptors when one API group is unavailable.
                firstPartialFailure ??= ex;
            }
        }

        if (result.Count == 0 && firstPartialFailure is not null) throw firstPartialFailure;

        IReadOnlyList<KubeResourceDescriptor> snapshot = result.ToArray();
        _cache[cacheKey] = snapshot;
        return snapshot;
    }

    private async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetAllResourcesCoreAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        string cacheKey = $"{_sessions.GetDiscoveryCacheIdentity(target, executionContext)}|all";
        if (!refresh && _cache.TryGetValue(cacheKey, out IReadOnlyList<KubeResourceDescriptor>? cached)) return cached;

        using CancellationTokenSource? timeout = KubernetesRequestContext.CreateTimeoutSource(executionContext.Timeout, cancellationToken);
        CancellationToken effectiveToken = timeout?.Token ?? cancellationToken;
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers = KubernetesRequestContext.BuildHeaders(executionContext);

        using ManagedSession session = _sessions.Create(target);
        using HttpOperationResponse<V1APIVersions> coreResponse = await session.Client.Core.GetAPIVersionsWithHttpMessagesAsync(
            customHeaders: headers, cancellationToken: effectiveToken).ConfigureAwait(false);
        using HttpOperationResponse<V1APIGroupList> groupResponse = await session.Client.Apis.GetAPIVersionsWithHttpMessagesAsync(
            customHeaders: headers, cancellationToken: effectiveToken).ConfigureAwait(false);

        List<string> apiVersions = new();
        foreach (string version in coreResponse.Body.Versions ?? Array.Empty<string>())
            if (!string.IsNullOrWhiteSpace(version)) apiVersions.Add(version);
        foreach (V1APIGroup group in groupResponse.Body.Groups ?? Array.Empty<V1APIGroup>())
        foreach (var version in group.Versions ?? Array.Empty<V1GroupVersionForDiscovery>())
            if (!string.IsNullOrWhiteSpace(version.GroupVersion)) apiVersions.Add(version.GroupVersion);

        List<KubeResourceDescriptor> result = new();
        HttpOperationException? firstPartialFailure = null;
        foreach (string apiVersion in apiVersions.Distinct(StringComparer.Ordinal))
        {
            try
            {
                IReadOnlyList<KubeResourceDescriptor> resources = await GetApiVersionResourcesCoreAsync(
                    apiVersion, target, executionContext, refresh, effectiveToken).ConfigureAwait(false);
                result.AddRange(resources);
            }
            catch (HttpOperationException ex)
            {
                firstPartialFailure ??= ex;
            }
        }

        if (result.Count == 0 && firstPartialFailure is not null) throw firstPartialFailure;
        IReadOnlyList<KubeResourceDescriptor> snapshot = result.ToArray();
        _cache[cacheKey] = snapshot;
        return snapshot;
    }

    private async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesCoreAsync(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(apiVersion)) throw new ArgumentException("API version is required.", nameof(apiVersion));
        string cacheKey = $"{_sessions.GetDiscoveryCacheIdentity(target, executionContext)}|{apiVersion}";
        if (!refresh && _cache.TryGetValue(cacheKey, out IReadOnlyList<KubeResourceDescriptor>? cached)) return cached;

        using CancellationTokenSource? timeout = KubernetesRequestContext.CreateTimeoutSource(executionContext.Timeout, cancellationToken);
        CancellationToken effectiveToken = timeout?.Token ?? cancellationToken;
        using ManagedSession session = _sessions.Create(target);
        IReadOnlyDictionary<string, IReadOnlyList<string>>? headers = KubernetesRequestContext.BuildHeaders(executionContext);
        V1APIResourceList body;
        if (string.Equals(apiVersion, "v1", StringComparison.Ordinal))
        {
            using HttpOperationResponse<V1APIResourceList> response = await session.Client.CoreV1.GetAPIResourcesWithHttpMessagesAsync(
                customHeaders: headers, cancellationToken: effectiveToken).ConfigureAwait(false);
            body = response.Body;
        }
        else
        {
            string[] parts = apiVersion.Split('/', 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2) throw new ArgumentException("Non-core API versions must use group/version form.", nameof(apiVersion));
            using HttpOperationResponse<V1APIResourceList> response = await session.Client.CustomObjects.GetAPIResourcesWithHttpMessagesAsync(
                parts[0], parts[1], customHeaders: headers, cancellationToken: effectiveToken).ConfigureAwait(false);
            body = response.Body;
        }

        IReadOnlyList<KubeResourceDescriptor> result = Map(body);
        _cache[cacheKey] = result;
        return result;
    }

    private async ValueTask<KubeResourceDescriptor?> ResolveResourceCoreAsync(
        GroupVersionResource resource,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(resource.Resource)) return null;

        if (resource.IsResolved)
        {
            IReadOnlyList<KubeResourceDescriptor> exact = await GetApiVersionResourcesCoreAsync(
                resource.ApiVersion, target, executionContext, refresh, cancellationToken).ConfigureAwait(false);
            return KubeDiscoveryResolution.Resolve(
                resource, exact, exact, target, "managed.discovery.ambiguous-resource");
        }

        // [D2/D9] Unresolved discovery must see every served version, while preferring the
        // server's preferred descriptor for one logical GroupResource. Alias ambiguity is
        // evaluated across logical GroupResources, never across versions of the same resource.
        IReadOnlyList<KubeResourceDescriptor> all = await GetAllResourcesCoreAsync(
            target, executionContext, refresh, cancellationToken).ConfigureAwait(false);
        IReadOnlyList<KubeResourceDescriptor> preferred = await GetPreferredResourcesCoreAsync(
            target, executionContext, refresh, cancellationToken).ConfigureAwait(false);
        return KubeDiscoveryResolution.Resolve(
            resource, all, preferred, target, "managed.discovery.ambiguous-resource");
    }

    private static async ValueTask<T> TranslateAsync<T>(Func<ValueTask<T>> action, KubeTarget target)
    {
        try { return await action().ConfigureAwait(false); }
        catch (KubeException) { throw; }
        catch (HttpOperationException ex) { throw KubernetesResponseMapper.FromHttpException(ex, target); }
        catch (OperationCanceledException ex)
        {
            throw new KubeException(
                KubeErrorKind.Cancelled,
                "Kubernetes discovery was cancelled.",
                ex,
                target: target,
                code: "managed.cancelled");
        }
    }

    private static IReadOnlyList<KubeResourceDescriptor> Map(V1APIResourceList body)
    {
        string[] gv = body.GroupVersion.Split('/', 2, StringSplitOptions.RemoveEmptyEntries);
        string group = gv.Length == 2 ? gv[0] : string.Empty;
        string version = gv.Length == 2 ? gv[1] : gv[0];
        Dictionary<string, (V1APIResource? Base, Dictionary<string, V1APIResource> Subs)> grouped = new(StringComparer.Ordinal);
        foreach (V1APIResource resource in body.Resources)
        {
            string[] name = resource.Name.Split('/', 2, StringSplitOptions.RemoveEmptyEntries);
            if (!grouped.TryGetValue(name[0], out var entry))
                entry = (null, new Dictionary<string, V1APIResource>(StringComparer.OrdinalIgnoreCase));
            if (name.Length == 1) entry.Base = resource;
            else entry.Subs[name[1]] = resource;
            grouped[name[0]] = entry;
        }

        return grouped
            .Where(pair => pair.Value.Base is not null) // [D9] orphan subresources do not invent a top-level resource
            .Select(pair =>
            {
                V1APIResource baseResource = pair.Value.Base!;
                KubeSubresourceDescriptor[] subresources = pair.Value.Subs.Select(sub => new KubeSubresourceDescriptor(
                    sub.Key,
                    string.IsNullOrWhiteSpace(sub.Value.Group) ? group : sub.Value.Group,
                    string.IsNullOrWhiteSpace(sub.Value.Version) ? version : sub.Value.Version,
                    sub.Value.Kind,
                    sub.Value.Namespaced,
                    sub.Value.Verbs)).ToArray();
                return KubeResourceDescriptor.Create(
                    new GroupVersionResource(group, version, pair.Key),
                    baseResource.Kind,
                    baseResource.Namespaced,
                    baseResource.Verbs,
                    singularName: baseResource.SingularName,
                    shortNames: baseResource.ShortNames,
                    categories: baseResource.Categories,
                    subresourceDetails: subresources);
            }).ToArray();
    }
}
