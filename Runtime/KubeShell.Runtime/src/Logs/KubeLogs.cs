using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace KubeShell.Runtime;

public sealed record KubeLogRequest(
    string Pod,
    KubeNamespaceScope Namespace,
    string? Container = null,
    long TailLines = 200,
    TimeSpan? Since = null,
    bool Previous = false,
    bool Follow = false,
    bool Timestamps = false,
    bool Prefix = false);

public interface IKubeLogBackend
{
    IAsyncEnumerable<string> ReadLogsAsync(
        KubeLogRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public sealed class KubeLogClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeLogClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeLogClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public IEnumerable<string> ReadLogs(
        KubeTarget target,
        KubeLogRequest request,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(request);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        IKubeLogBackend backend = _selector.SelectCapabilityAsync(
            new KubeLogCapabilityRequest(request), target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
        IAsyncEnumerator<string> enumerator = backend.ReadLogsAsync(request, target, context, cancellationToken).GetAsyncEnumerator(cancellationToken);
        try
        {
            while (enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult()) yield return enumerator.Current;
        }
        finally
        {
            enumerator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }
}
