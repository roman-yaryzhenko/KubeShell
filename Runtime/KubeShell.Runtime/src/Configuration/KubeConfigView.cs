using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public sealed record KubeConfigContextInfo(string Name, string? Cluster, string? User, string? Namespace);

public sealed record KubeConfigView(string? CurrentContext, IReadOnlyList<KubeConfigContextInfo> Contexts);

public interface IKubeConfigBackend
{
    ValueTask<KubeConfigView> GetConfigViewAsync(
        KubeTarget target,
        CancellationToken cancellationToken = default);
}

public interface IKubeConfigClient
{
    KubeConfigView GetConfigView(KubeTarget target, CancellationToken cancellationToken = default);
}

/// <summary>
/// Exposes the client-go-resolved kubeconfig view without leaking clientcmd types across the Runtime
/// boundary. KubeShell keeps context/namespace overrides session-local and does not rewrite files.
/// </summary>
public sealed class KubeConfigClient : IKubeConfigClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeConfigClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeConfigClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public KubeConfigView GetConfigView(KubeTarget target, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubeExecutionContext context = KubeExecutionContext.Default;
        IKubeConfigBackend backend = _selector.SelectCapabilityAsync(
            new KubeConfigCapabilityRequest(), target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
        return backend.GetConfigViewAsync(target, cancellationToken).AsTask().GetAwaiter().GetResult();
    }
}
