using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public sealed record KubeCopyRequest(
    string Pod,
    KubeNamespaceScope Namespace,
    string LocalPath,
    string RemotePath,
    bool ToPod,
    string? Container = null);

public sealed record KubeCopyResult(string? Output = null, string? ErrorOutput = null);

public interface IKubeCopyBackend
{
    ValueTask<KubeCopyResult> CopyAsync(
        KubeCopyRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public sealed class KubeCopyClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeCopyClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeCopyClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public KubeCopyResult Copy(KubeTarget target, KubeCopyRequest request, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(request);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        IKubeCopyBackend backend = _selector.SelectCapabilityAsync(
            new KubeCopyCapabilityRequest(request), target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
        return backend.CopyAsync(request, target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }
}
