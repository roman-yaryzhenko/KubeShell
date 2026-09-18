using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public interface IKubeDiscoveryClient
{
    IReadOnlyList<KubeResourceDescriptor> GetPreferredResources(
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    IReadOnlyList<KubeResourceDescriptor> GetApiVersionResources(
        KubeTarget target,
        string apiVersion,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    KubeResourceDescriptor? ResolveResource(
        KubeTarget target,
        GroupVersionResource resource,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        KubeTarget target,
        string apiVersion,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default);

    ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        KubeTarget target,
        GroupVersionResource resource,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Backend-neutral discovery facade. Async members are the primary application-facing boundary;
/// synchronous members remain for shell/framework call sites that cannot be async.
/// </summary>
public sealed class KubeDiscoveryClient : IKubeDiscoveryClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeDiscoveryClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));
    public KubeDiscoveryClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public IReadOnlyList<KubeResourceDescriptor> GetPreferredResources(
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        GetPreferredResourcesAsync(target, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public IReadOnlyList<KubeResourceDescriptor> GetApiVersionResources(
        KubeTarget target,
        string apiVersion,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        GetApiVersionResourcesAsync(target, apiVersion, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public KubeResourceDescriptor? ResolveResource(
        KubeTarget target,
        GroupVersionResource resource,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        ResolveResourceAsync(target, resource, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        try
        {
            IKubeDiscoveryBackend backend = await _selector.SelectCapabilityAsync(
                new KubeDiscoveryCapabilityRequest(KubeDiscoveryCapabilityKind.PreferredResources, refresh),
                target, context, cancellationToken).ConfigureAwait(false);
            return await backend.GetPreferredResourcesAsync(target, context, refresh, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex)
        {
            throw RuntimeCancellation(ex, target);
        }
    }

    public async ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        KubeTarget target,
        string apiVersion,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (string.IsNullOrWhiteSpace(apiVersion)) throw new ArgumentException("API version is required.", nameof(apiVersion));
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        try
        {
            IKubeDiscoveryBackend backend = await _selector.SelectCapabilityAsync(
                new KubeDiscoveryCapabilityRequest(KubeDiscoveryCapabilityKind.ApiVersionResources, refresh, ApiVersion: apiVersion),
                target, context, cancellationToken).ConfigureAwait(false);
            return await backend.GetApiVersionResourcesAsync(apiVersion, target, context, refresh, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex)
        {
            throw RuntimeCancellation(ex, target);
        }
    }

    public async ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        KubeTarget target,
        GroupVersionResource resource,
        KubeExecutionContext? executionContext = null,
        bool refresh = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        try
        {
            IKubeDiscoveryBackend backend = await _selector.SelectCapabilityAsync(
                new KubeDiscoveryCapabilityRequest(KubeDiscoveryCapabilityKind.ResolveResource, refresh, Resource: resource),
                target, context, cancellationToken).ConfigureAwait(false);
            return await backend.ResolveResourceAsync(resource, target, context, refresh, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex)
        {
            throw RuntimeCancellation(ex, target);
        }
    }

    private static KubeException RuntimeCancellation(OperationCanceledException exception, KubeTarget target) =>
        new(KubeErrorKind.Cancelled, "Kubernetes discovery was cancelled.", exception, target: target, code: "runtime.discovery.cancelled");
}
