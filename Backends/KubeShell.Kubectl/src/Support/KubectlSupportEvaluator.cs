using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlSupportEvaluator
{
    private readonly KubectlHostProcess _host;
    private readonly KubectlDiscoveryService _discovery;

    internal KubectlSupportEvaluator(KubectlHostProcess host, KubectlDiscoveryService discovery)
    {
        _host = host;
        _discovery = discovery;
    }

    internal async ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        KubeOperationSupport? semantic = EvaluateLocalSemantics(operation);
        if (semantic is not null) return semantic;

        // KubeTarget is resolved above the backend boundary. The host intentionally never guesses
        // KUBECONFIG or ~/.kube/config, so an unresolved target is unavailable rather than ambient.
        if (target.KubeConfigPaths.Length == 0)
            return KubeOperationSupport.Unavailable("kubectl.target.kubeconfig", "kubectl-host requires explicit kubeconfig path(s) in KubeTarget.");

        KubectlHostConnection connection;
        try { connection = await _host.GetConnectionAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return KubeOperationSupport.Unavailable("kubectl-host.unavailable", ex.Message); }

        WireProtocol.Features required = RequiredFeatures(operation, executionContext);
        WireProtocol.Features missing = required & ~(WireProtocol.Features)connection.Client.HelloAck.FeatureBits;
        if (missing != 0)
            return KubeOperationSupport.Unsupported("kubectl-host.features", $"kubectl-host does not advertise required feature(s): {missing}.");

        GroupVersionResource gvr = GetGvr(operation);
        try
        {
            KubeResourceDescriptor? descriptor = await _discovery.ResolveResourceAsync(gvr, target, executionContext, false, cancellationToken).ConfigureAwait(false);
            if (descriptor is null) return KubeOperationSupport.Unknown("kubectl.discovery.empty", $"Discovery did not resolve '{gvr}'.");
            return EvaluateDiscoveredOperation(operation, descriptor);
        }
        catch (OperationCanceledException) { throw; }
        catch (KubeException ex)
        {
            return ClassifyDiscoveryFailure(ex);
        }
    }

    internal async ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(
        KubeCapabilityRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        // Watch has a normal KubeOperation shape, so reuse the stricter operation evaluator including
        // discovery verb checks instead of maintaining a second interpretation of watch semantics.
        if (request is KubeWatchCapabilityRequest watch)
            return await EvaluateAsync(watch.Operation, target, executionContext, cancellationToken).ConfigureAwait(false);

        if (target.KubeConfigPaths.Length == 0)
            return KubeOperationSupport.Unavailable("kubectl.target.kubeconfig", "kubectl-host requires explicit kubeconfig path(s) in KubeTarget.");

        KubectlHostConnection connection;
        try { connection = await _host.GetConnectionAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return KubeOperationSupport.Unavailable("kubectl-host.unavailable", ex.Message); }

        WireProtocol.Features required = request switch
        {
            KubeDiscoveryCapabilityRequest => WireProtocol.Features.Discovery,
            KubeConfigCapabilityRequest => (WireProtocol.Features)0,
            KubeSchemaCapabilityRequest => WireProtocol.Features.Schema,
            KubeLogCapabilityRequest => WireProtocol.Features.Logs,
            KubeCopyCapabilityRequest => WireProtocol.Features.Copy,
            KubeDebugCapabilityRequest => WireProtocol.Features.Debug,
            KubeAccessReviewCapabilityRequest or KubePodMetricsCapabilityRequest or
                KubeNodeMetricsCapabilityRequest or KubeDnsProbeCapabilityRequest => WireProtocol.Features.Diagnostics,
            _ => (WireProtocol.Features)0
        };
        if (executionContext.Impersonation is not null)
            required |= WireProtocol.Features.Impersonation;

        if (request is not (KubeDiscoveryCapabilityRequest or KubeConfigCapabilityRequest or KubeSchemaCapabilityRequest or
            KubeLogCapabilityRequest or KubeCopyCapabilityRequest or KubeDebugCapabilityRequest or
            KubeAccessReviewCapabilityRequest or KubePodMetricsCapabilityRequest or KubeNodeMetricsCapabilityRequest or
            KubeDnsProbeCapabilityRequest))
            return KubeOperationSupport.Unsupported("kubectl-host.capability", $"kubectl-host does not implement semantic capability {request.GetType().Name}.");

        WireProtocol.Features missing = required & ~(WireProtocol.Features)connection.Client.HelloAck.FeatureBits;
        if (missing != 0)
            return KubeOperationSupport.Unsupported("kubectl-host.features", $"kubectl-host does not advertise required feature(s): {missing}.");

        if (request is KubeDebugCapabilityRequest debug)
            return await EvaluateDebugAsync(debug.Request, target, executionContext, cancellationToken).ConfigureAwait(false);

        return KubeOperationSupport.Supported(
            "kubectl-host.capability.supported",
            "kubectl-host advertises the protocol capability required by this semantic request.");
    }

    private async ValueTask<KubeOperationSupport> EvaluateDebugAsync(
        KubeDebugRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(request.Target.Subresource))
            return KubeOperationSupport.Unsupported("debug.subresource", "kubectl debug does not target a generic Kubernetes subresource.");

        try
        {
            KubeResourceDescriptor? descriptor = await _discovery.ResolveResourceAsync(
                request.Target.Gvr, target, executionContext, false, cancellationToken).ConfigureAwait(false);
            if (descriptor is null)
                return KubeOperationSupport.Unknown("debug.discovery.empty", $"Discovery did not resolve '{request.Target.Gvr}'.");

            bool coreV1 = string.IsNullOrWhiteSpace(descriptor.Gvr.Group) &&
                string.Equals(descriptor.Gvr.Version, "v1", StringComparison.OrdinalIgnoreCase);
            bool supportedKind = string.Equals(descriptor.Kind, "Pod", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(descriptor.Kind, "Node", StringComparison.OrdinalIgnoreCase);
            if (!coreV1 || !supportedKind)
                return KubeOperationSupport.Unsupported(
                    "debug.kind",
                    $"{descriptor.Gvr} ({descriptor.Kind ?? "unknown kind"}) is outside the kubectl-host debug surface.");

            return KubeOperationSupport.Supported(
                "kubectl-host.debug.supported",
                "kubectl-host debug supports the resolved core/v1 Pod or Node target.");
        }
        catch (OperationCanceledException) { throw; }
        catch (KubeException ex) { return ClassifyDiscoveryFailure(ex); }
    }

    private static KubeOperationSupport EvaluateDiscoveredOperation(KubeOperation operation, KubeResourceDescriptor descriptor)
    {
        return operation switch
        {
            KubeScaleOperation scale => EvaluateScale(scale, descriptor),
            KubeRolloutUndoOperation undo => EvaluateRolloutUndo(undo, descriptor),
            KubeRolloutRestartOperation restart => EvaluateRolloutRestart(restart, descriptor),
            KubeSetImageOperation setImage => EvaluateSetImage(setImage, descriptor),
            KubeRolloutStatusOperation => EvaluateRolloutStatus(descriptor),
            _ => EvaluateGenericOperation(operation, descriptor)
        };
    }

    private static KubeOperationSupport EvaluateGenericOperation(KubeOperation operation, KubeResourceDescriptor descriptor)
    {
        string verb = RequiredVerb(operation);
        IReadOnlySet<string> verbs = descriptor.Verbs;
        string? subresource = GetSubresource(operation);
        if (!string.IsNullOrWhiteSpace(subresource))
        {
            if (!descriptor.SubresourceDetails.TryGetValue(subresource, out KubeSubresourceDescriptor? sub) || sub is null)
                return KubeOperationSupport.Unsupported("kubectl.subresource.discovery", $"Discovery does not expose subresource '{subresource}' for {descriptor.Gvr}.");
            verbs = sub.Verbs;
        }
        if (!verbs.Contains(verb))
            return KubeOperationSupport.Unsupported("kubectl.api-verb", $"Discovery for {descriptor.Gvr} does not advertise verb '{verb}'.");
        return Supported(descriptor, "the requested operation shape");
    }

    private static KubeOperationSupport EvaluateScale(KubeScaleOperation operation, KubeResourceDescriptor descriptor)
    {
        if (!descriptor.Verbs.Contains("get"))
            return MissingVerb(descriptor, "get", "scale reads the current workload before producing a result");

        if (operation.Preview == KubePreviewMode.Client)
            return Supported(descriptor, "client-side scale preview");

        if (!descriptor.SubresourceDetails.TryGetValue("scale", out KubeSubresourceDescriptor? scale) || scale is null)
            return KubeOperationSupport.Unsupported("kubectl.scale.subresource", $"Discovery does not expose the scale subresource for {descriptor.Gvr}.");
        if (!scale.Verbs.Contains("patch"))
            return KubeOperationSupport.Unsupported("kubectl.scale.patch", $"The scale subresource for {descriptor.Gvr} does not advertise patch.");
        return Supported(descriptor, "scale subresource patch");
    }

    private static KubeOperationSupport EvaluateRolloutUndo(KubeRolloutUndoOperation operation, KubeResourceDescriptor descriptor)
    {
        if (!descriptor.Namespaced)
            return KubeOperationSupport.Unsupported("rollout.undo.scope", "Rollout undo requires a namespaced workload.");
        if (!KindIn(descriptor, "Deployment", "DaemonSet", "StatefulSet"))
            return KubeOperationSupport.Unsupported("rollout.undo.kind", $"kubectl rollback machinery does not support {descriptor.Kind ?? descriptor.Gvr.Resource}.");
        if (!descriptor.Verbs.Contains("get"))
            return MissingVerb(descriptor, "get", "rollout undo reads the current workload");
        if (operation.Preview != KubePreviewMode.Client && !descriptor.Verbs.Contains("patch"))
            return MissingVerb(descriptor, "patch", "rollout undo mutates workload revision state");
        return Supported(descriptor, "rollout undo");
    }

    private static KubeOperationSupport EvaluateRolloutRestart(KubeRolloutRestartOperation operation, KubeResourceDescriptor descriptor)
    {
        if (!KindIn(descriptor, "Deployment", "DaemonSet", "StatefulSet"))
            return KubeOperationSupport.Unsupported("rollout.restart.kind", $"kubectl rollout restart does not support {descriptor.Kind ?? descriptor.Gvr.Resource}.");
        return EvaluateGetAndOptionalPatch(operation.Preview, descriptor, "rollout restart");
    }

    private static KubeOperationSupport EvaluateSetImage(KubeSetImageOperation operation, KubeResourceDescriptor descriptor)
    {
        if (!KindIn(descriptor, "Pod", "ReplicationController", "Deployment", "DaemonSet", "ReplicaSet", "StatefulSet", "CronJob"))
            return KubeOperationSupport.Unsupported("set-image.kind", $"kubectl set image does not expose pod-template semantics for {descriptor.Kind ?? descriptor.Gvr.Resource}.");
        return EvaluateGetAndOptionalPatch(operation.Preview, descriptor, "set image");
    }

    private static KubeOperationSupport EvaluateRolloutStatus(KubeResourceDescriptor descriptor)
    {
        if (!KindIn(descriptor, "Deployment", "DaemonSet", "StatefulSet"))
            return KubeOperationSupport.Unsupported("rollout.status.kind", $"kubectl rollout status does not support {descriptor.Kind ?? descriptor.Gvr.Resource}.");
        if (!descriptor.Verbs.Contains("get"))
            return MissingVerb(descriptor, "get", "rollout status polls the workload");
        return Supported(descriptor, "rollout status");
    }

    private static KubeOperationSupport EvaluateGetAndOptionalPatch(KubePreviewMode preview, KubeResourceDescriptor descriptor, string operation)
    {
        if (!descriptor.Verbs.Contains("get"))
            return MissingVerb(descriptor, "get", operation + " reads the current workload");
        if (preview != KubePreviewMode.Client && !descriptor.Verbs.Contains("patch"))
            return MissingVerb(descriptor, "patch", operation + " mutates the workload");
        return Supported(descriptor, operation);
    }

    private static bool KindIn(KubeResourceDescriptor descriptor, params string[] kinds) =>
        kinds.Any(kind => string.Equals(descriptor.Kind, kind, StringComparison.OrdinalIgnoreCase));

    private static KubeOperationSupport MissingVerb(KubeResourceDescriptor descriptor, string verb, string reason) =>
        KubeOperationSupport.Unsupported("kubectl.api-verb", $"Discovery for {descriptor.Gvr} does not advertise verb '{verb}', but {reason}.");

    private static KubeOperationSupport Supported(KubeResourceDescriptor descriptor, string capability) =>
        KubeOperationSupport.Supported(
            "kubectl-host.supported",
            $"kubectl-host and the discovered API resource support {capability} for {descriptor.Gvr}.");

    private static KubeOperationSupport ClassifyDiscoveryFailure(KubeException ex) => ex.Kind switch
    {
        KubeErrorKind.Configuration or KubeErrorKind.Transport or KubeErrorKind.Unavailable =>
            KubeOperationSupport.Unavailable(ex.Code ?? "kubectl.discovery.unavailable", ex.Message),
        KubeErrorKind.InvalidResource or KubeErrorKind.NotFound or KubeErrorKind.Unsupported =>
            KubeOperationSupport.Unsupported(ex.Code ?? "kubectl.discovery.no-match", ex.Message),
        _ => KubeOperationSupport.Unknown(ex.Code ?? "kubectl.discovery", ex.Message)
    };

    private static KubeOperationSupport? EvaluateLocalSemantics(KubeOperation operation)
    {
        if (operation is not (KubeGetOperation or KubeListOperation or KubeCreateOperation or KubeReplaceOperation or
            KubeDeleteOperation or KubePatchOperation or KubeApplyOperation or KubeWatchOperation or KubeRolloutUndoOperation or
            KubeRolloutRestartOperation or KubeScaleOperation or KubeSetImageOperation or KubeRolloutStatusOperation))
            return KubeOperationSupport.Unsupported("kubectl.operation", $"kubectl-host does not implement operation {operation.GetType().Name} in protocol v1.");
        if (operation is KubeListOperation list && !string.IsNullOrWhiteSpace(list.Query.Subresource))
            return KubeOperationSupport.Unsupported("kubectl.list-subresource", "Generic subresource list is not implemented by protocol v1.");
        if (operation is KubeWatchOperation watch && !string.IsNullOrWhiteSpace(watch.Query.Subresource))
            return KubeOperationSupport.Unsupported("kubectl.watch-subresource", "Generic subresource watch is not implemented by protocol v1.");
        if (operation is KubeApplyOperation applySubresource &&
            !string.IsNullOrWhiteSpace(applySubresource.Identity.Subresource) &&
            applySubresource.Options.Strategy == KubeApplyStrategy.ClientSide)
            return KubeOperationSupport.Unsupported("kubectl.apply.client-subresource", "kubectl apply supports subresources only with server-side apply.");

        KubePreviewMode preview = GetPreview(operation);
        if (preview == KubePreviewMode.Client && operation is not (KubeApplyOperation or KubeRolloutUndoOperation or KubeRolloutRestartOperation or KubeScaleOperation or KubeSetImageOperation))
            return KubeOperationSupport.Unsupported("kubectl.client-preview.operation", "Protocol v1 implements client preview only for apply and reviewed workload operations; other generic client-preview commands remain fail-closed.");
        if (operation is KubePatchOperation patch && patch.Options.Concurrency.Mode != KubeConcurrencyMode.Default)
            return KubeOperationSupport.Unsupported("kubectl.patch-concurrency", "Generic patch has no backend-neutral resourceVersion precondition in protocol v1.");
        if (operation is KubeReplaceOperation replace && replace.Options.Concurrency.Mode == KubeConcurrencyMode.Force)
            return KubeOperationSupport.Unsupported("kubectl.replace-force", "Replace has no portable forced-overwrite semantic.");
        if (operation is KubeDeleteOperation delete && delete.Options.Concurrency.Mode == KubeConcurrencyMode.Force)
            return KubeOperationSupport.Unsupported("kubectl.delete-concurrency-force", "Delete concurrency Force is distinct from deletion Force and is not defined by protocol v1.");
        return null;
    }

    private static WireProtocol.Features RequiredFeatures(KubeOperation operation, KubeExecutionContext executionContext)
    {
        WireProtocol.Features features = operation switch
        {
            KubeWatchOperation => WireProtocol.Features.Watch,
            KubeRolloutUndoOperation => WireProtocol.Features.RolloutUndo,
            KubeRolloutRestartOperation or KubeScaleOperation or KubeSetImageOperation or KubeRolloutStatusOperation => WireProtocol.Features.Workloads,
            _ => WireProtocol.Features.Crud
        };
        if (operation is KubeApplyOperation apply)
            features |= apply.Options.Strategy == KubeApplyStrategy.ClientSide ? WireProtocol.Features.ClientSideApply : WireProtocol.Features.ServerSideApply;
        if (GetPreview(operation) == KubePreviewMode.Server) features |= WireProtocol.Features.ServerPreview;
        if (GetPreview(operation) == KubePreviewMode.Client) features |= WireProtocol.Features.ClientPreview;
        if (!string.IsNullOrWhiteSpace(GetSubresource(operation))) features |= WireProtocol.Features.Subresources;
        if (executionContext.Impersonation is not null) features |= WireProtocol.Features.Impersonation;
        if (executionContext.FieldValidation != KubeFieldValidationMode.Default) features |= WireProtocol.Features.FieldValidation;
        return features;
    }

    private static GroupVersionResource GetGvr(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => x.Identity.Gvr,
        KubeListOperation x => x.Query.Gvr,
        KubeCreateOperation x => x.Identity.Gvr,
        KubeReplaceOperation x => x.Identity.Gvr,
        KubeDeleteOperation x => x.Identity.Gvr,
        KubePatchOperation x => x.Identity.Gvr,
        KubeApplyOperation x => x.Identity.Gvr,
        KubeWatchOperation x => x.Query.Gvr,
        KubeRolloutUndoOperation x => x.Identity.Gvr,
        KubeRolloutRestartOperation x => x.Identity.Gvr,
        KubeScaleOperation x => x.Identity.Gvr,
        KubeSetImageOperation x => x.Identity.Gvr,
        KubeRolloutStatusOperation x => x.Identity.Gvr,
        _ => default
    };

    private static string RequiredVerb(KubeOperation operation) => operation switch
    {
        KubeGetOperation => "get",
        KubeListOperation => "list",
        KubeCreateOperation => "create",
        KubeReplaceOperation => "update",
        KubeDeleteOperation => "delete",
        KubePatchOperation or KubeApplyOperation => "patch",
        KubeWatchOperation => "watch",
        _ => string.Empty
    };

    private static string? GetSubresource(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => x.Identity.Subresource,
        KubeListOperation x => x.Query.Subresource,
        KubeCreateOperation x => x.Identity.Subresource,
        KubeReplaceOperation x => x.Identity.Subresource,
        KubeDeleteOperation x => x.Identity.Subresource,
        KubePatchOperation x => x.Identity.Subresource,
        KubeApplyOperation x => x.Identity.Subresource,
        KubeWatchOperation x => x.Query.Subresource,
        KubeRolloutUndoOperation x => x.Identity.Subresource,
        KubeRolloutRestartOperation x => x.Identity.Subresource,
        KubeScaleOperation x => x.Identity.Subresource,
        KubeSetImageOperation x => x.Identity.Subresource,
        KubeRolloutStatusOperation x => x.Identity.Subresource,
        _ => null
    };

    private static KubePreviewMode GetPreview(KubeOperation operation) => operation switch
    {
        KubeCreateOperation x => x.Options.Preview,
        KubeReplaceOperation x => x.Options.Preview,
        KubeDeleteOperation x => x.Options.Preview,
        KubePatchOperation x => x.Options.Preview,
        KubeApplyOperation x => x.Options.Preview,
        KubeRolloutUndoOperation x => x.Preview,
        KubeRolloutRestartOperation x => x.Preview,
        KubeScaleOperation x => x.Preview,
        KubeSetImageOperation x => x.Preview,
        _ => KubePreviewMode.None
    };
}
