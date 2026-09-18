using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace KubeShell.Runtime;

public enum KubeWatchEventType
{
    Added,
    Modified,
    Deleted,
    Bookmark,
    Error
}

public sealed record KubeWatchEvent(
    KubeWatchEventType Type,
    KubeResource? Resource = null,
    KubeError? Error = null,
    string? ResourceVersion = null);

public interface IKubeWatchClient
{
    IEnumerable<KubeWatchEvent> Watch(
        KubeTarget target,
        KubeWatchOperation operation,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Synchronous facade for shell consumers over backend-native async watch streams. PowerShell's
/// pipeline is synchronous, while the transport remains IAsyncEnumerable end-to-end below this
/// boundary. Backend ordering follows the same semantics-preserving rules as KubeOperationClient.
/// </summary>
public sealed class KubeWatchClient : IKubeWatchClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeWatchClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeWatchClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public IEnumerable<KubeWatchEvent> Watch(
        KubeTarget target,
        KubeWatchOperation operation,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(operation);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        IKubeWatchBackend backend = _selector.SelectCapabilityAsync(
            new KubeWatchCapabilityRequest(operation), target, context, cancellationToken).AsTask().GetAwaiter().GetResult();

        IAsyncEnumerator<KubeWatchEvent> enumerator = backend.WatchAsync(operation, target, context, cancellationToken).GetAsyncEnumerator(cancellationToken);
        try
        {
            while (enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult())
                yield return enumerator.Current;
        }
        finally
        {
            enumerator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }
}
