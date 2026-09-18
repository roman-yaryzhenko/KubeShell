using System;
using System.Collections.Generic;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using k8s;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

/// <summary>
/// Managed Kubernetes API backend. This public adapter owns only support evaluation and delegation;
/// session construction, discovery/cache, API execution and response mapping are separate components.
/// </summary>
public sealed class KubernetesClientBackend : IKubeBackend, IKubeDiscoveryBackend, IKubeCapabilityEvaluator
{
    private readonly KubernetesSessionFactory _sessions;
    private readonly KubernetesDiscoveryService _discovery;
    private readonly KubernetesOperationExecutor _executor;

    public KubernetesClientBackend() : this(new KubernetesSessionFactory()) { }

    public KubernetesClientBackend(KubernetesClientConfiguration configuration)
        : this(new KubernetesSessionFactory(configuration ?? throw new ArgumentNullException(nameof(configuration)))) { }

    private KubernetesClientBackend(KubernetesSessionFactory sessions)
    {
        _sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
        _discovery = new KubernetesDiscoveryService(_sessions);
        _executor = new KubernetesOperationExecutor(_sessions);
    }

    public static KubernetesClientBackend CreateExplicit(
        Uri server,
        string? bearerToken = null,
        X509Certificate2? clientCertificate = null,
        X509Certificate2? certificateAuthority = null,
        bool skipCertificateCheck = false,
        string? defaultNamespace = null) =>
        new(KubernetesSessionFactory.CreateExplicitConfiguration(
            server,
            bearerToken,
            clientCertificate,
            certificateAuthority,
            skipCertificateCheck,
            defaultNamespace));

    public string Id => "kubernetes-client";

    public IReadOnlyList<KubeResourceDescriptor> GetPreferredResources(
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        bool refresh = false) =>
        GetPreferredResourcesAsync(target, executionContext ?? KubeExecutionContext.Default, refresh).GetAwaiter().GetResult();

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        _discovery.GetPreferredResourcesAsync(target, executionContext, refresh, cancellationToken);

    public IReadOnlyList<KubeResourceDescriptor> GetApiVersionResources(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext? executionContext = null,
        bool refresh = false) =>
        GetApiVersionResourcesAsync(apiVersion, target, executionContext ?? KubeExecutionContext.Default, refresh).GetAwaiter().GetResult();

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        string apiVersion,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        _discovery.GetApiVersionResourcesAsync(apiVersion, target, executionContext, refresh, cancellationToken);

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        GroupVersionResource resource,
        KubeTarget target,
        KubeExecutionContext executionContext,
        bool refresh = false,
        CancellationToken cancellationToken = default) =>
        _discovery.ResolveResourceAsync(resource, target, executionContext, refresh, cancellationToken);

    public async ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        KubeOperationSupport? local = EvaluateLocalSemantics(operation);
        if (local is not null) return local;

        GroupVersionResource gvr = GetGvr(operation)!.Value;
        try
        {
            // Discovery constructs the managed session from the explicit KubeTarget and proves the
            // concrete resource/verb before Supported is returned.
            KubeResourceDescriptor? descriptor = await _discovery
                .ResolveResourceAsync(gvr, target, executionContext, false, cancellationToken)
                .ConfigureAwait(false);
            if (descriptor is null)
                return KubeOperationSupport.Unknown(
                    "managed.discovery.empty",
                    $"Discovery did not resolve '{gvr}'.");

            string verb = RequiredVerb(operation);
            if (!descriptor.Verbs.Contains(verb))
                return KubeOperationSupport.Unsupported(
                    "managed.api-verb",
                    $"Discovery for {descriptor.Gvr} does not advertise verb '{verb}'.");

            return KubeOperationSupport.Supported(
                "managed.supported",
                "The managed backend, target and discovered API resource support the requested operation shape.");
        }
        catch (OperationCanceledException) { throw; }
        catch (KubeException ex) when (ex.Kind == KubeErrorKind.Cancelled) { throw; }
        catch (KubeException ex)
        {
            return ClassifyProbeFailure(ex);
        }
        catch (Exception ex)
        {
            return KubeOperationSupport.Unavailable("managed.target.unavailable", ex.Message);
        }
    }

    public ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(
        KubeCapabilityRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        if (request is not KubeDiscoveryCapabilityRequest)
            return ValueTask.FromResult(KubeOperationSupport.Unsupported(
                "managed.capability",
                $"The managed backend does not implement semantic capability {request.GetType().Name}."));

        try
        {
            // Discovery itself is the capability; do not perform a second network discovery here.
            // Session construction is enough to prove that this backend can address the selected target.
            using ManagedSession session = _sessions.Create(target);
            return ValueTask.FromResult(KubeOperationSupport.Supported(
                "managed.discovery",
                "The official KubernetesClient backend can resolve the selected target for discovery."));
        }
        catch (KubeException ex)
        {
            return ValueTask.FromResult(ClassifyProbeFailure(ex));
        }
        catch (Exception ex)
        {
            return ValueTask.FromResult(KubeOperationSupport.Unavailable("managed.target.unavailable", ex.Message));
        }
    }

    private static KubeOperationSupport? EvaluateLocalSemantics(KubeOperation operation)
    {
        if (operation is not (KubeGetOperation or KubeListOperation or KubeCreateOperation or KubeReplaceOperation or
            KubeApplyOperation or KubePatchOperation or KubeDeleteOperation))
            return KubeOperationSupport.Unsupported(
                "managed.operation",
                $"The managed backend does not implement operation {operation.GetType().Name}.");

        GroupVersionResource? gvr = GetGvr(operation);
        if (gvr.HasValue && !gvr.Value.IsResolved)
            return KubeOperationSupport.Unknown(
                "managed.discovery-required",
                "The managed backend requires a resolved group/version/resource. Discovery can resolve legacy resource names before routing.");

        if (HasSubresource(operation))
            return KubeOperationSupport.Unsupported("managed.subresource", "Generic subresource dispatch is not implemented by this backend yet.");

        if (GetPreview(operation) == KubePreviewMode.Client)
            return KubeOperationSupport.Unsupported("managed.client-preview", "Client-side preview is kubectl client machinery, not a Kubernetes API operation.");

        if (operation is KubeApplyOperation apply && apply.Options.Strategy != KubeApplyStrategy.ServerSide)
            return KubeOperationSupport.Unsupported("managed.client-side-apply", "The managed backend implements server-side apply only.");

        if (operation is KubePatchOperation patch && patch.Options.Concurrency.Mode != KubeConcurrencyMode.Default)
            return KubeOperationSupport.Unsupported("managed.patch-concurrency", "Generic patch does not have a backend-neutral resourceVersion precondition in this implementation.");

        if (operation is KubeDeleteOperation delete && delete.Options.Concurrency.Mode != KubeConcurrencyMode.Default)
            return KubeOperationSupport.Unsupported("managed.delete-concurrency", "Delete preconditions are not wired into the generic managed backend yet.");

        if (operation is KubeReplaceOperation replace && replace.Options.Concurrency.Mode == KubeConcurrencyMode.Force)
            return KubeOperationSupport.Unsupported("managed.replace-force", "Replace does not define a portable forced-overwrite semantic.");

        return null;
    }

    private static KubeOperationSupport ClassifyProbeFailure(KubeException exception) => exception.Kind switch
    {
        KubeErrorKind.Configuration or KubeErrorKind.Transport or KubeErrorKind.Unavailable =>
            KubeOperationSupport.Unavailable(exception.Code ?? "managed.discovery.unavailable", exception.Message),
        KubeErrorKind.InvalidResource or KubeErrorKind.NotFound or KubeErrorKind.Unsupported =>
            KubeOperationSupport.Unsupported(exception.Code ?? "managed.discovery.no-match", exception.Message),
        _ => KubeOperationSupport.Unknown(exception.Code ?? "managed.discovery", exception.Message)
    };

    private static string RequiredVerb(KubeOperation operation) => operation switch
    {
        KubeGetOperation => "get",
        KubeListOperation => "list",
        KubeCreateOperation => "create",
        KubeReplaceOperation => "update",
        KubeApplyOperation or KubePatchOperation => "patch",
        KubeDeleteOperation => "delete",
        _ => string.Empty
    };

    public async ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        KubeOperationSupport support = await EvaluateAsync(operation, target, executionContext, cancellationToken).ConfigureAwait(false);
        if (support.State != KubeSupportState.Supported)
            throw new KubeException(
                support.ToFailureKind(),
                support.Reason ?? "Managed backend does not support the requested operation.",
                code: support.ReasonCode,
                target: target);
        return await _executor.ExecuteAsync(operation, target, executionContext, cancellationToken).ConfigureAwait(false);
    }

    private static GroupVersionResource? GetGvr(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => x.Identity.Gvr,
        KubeListOperation x => x.Query.Gvr,
        KubeCreateOperation x => x.Identity.Gvr,
        KubeReplaceOperation x => x.Identity.Gvr,
        KubeApplyOperation x => x.Identity.Gvr,
        KubePatchOperation x => x.Identity.Gvr,
        KubeDeleteOperation x => x.Identity.Gvr,
        KubeWatchOperation x => x.Query.Gvr,
        _ => null
    };

    private static KubePreviewMode GetPreview(KubeOperation operation) => operation switch
    {
        KubeCreateOperation x => x.Options.Preview,
        KubeReplaceOperation x => x.Options.Preview,
        KubeApplyOperation x => x.Options.Preview,
        KubePatchOperation x => x.Options.Preview,
        KubeDeleteOperation x => x.Options.Preview,
        _ => KubePreviewMode.None
    };

    private static bool HasSubresource(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeListOperation x => !string.IsNullOrWhiteSpace(x.Query.Subresource),
        KubeCreateOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeReplaceOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeApplyOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubePatchOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeDeleteOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeWatchOperation x => !string.IsNullOrWhiteSpace(x.Query.Subresource),
        _ => false
    };
}
