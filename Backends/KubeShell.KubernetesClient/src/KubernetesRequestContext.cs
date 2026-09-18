using System;
using System.Collections.Generic;
using System.Threading;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

internal static class KubernetesRequestContext
{
    public static IReadOnlyDictionary<string, IReadOnlyList<string>>? BuildHeaders(KubeExecutionContext context)
    {
        Dictionary<string, IReadOnlyList<string>> headers = new(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(context.UserAgent)) headers["User-Agent"] = new[] { context.UserAgent! };
        if (!string.IsNullOrWhiteSpace(context.CorrelationId)) headers["X-KubeShell-Correlation-Id"] = new[] { context.CorrelationId! };
        if (context.Impersonation is { } impersonation)
        {
            if (!string.IsNullOrWhiteSpace(impersonation.User)) headers["Impersonate-User"] = new[] { impersonation.User! };
            if (!string.IsNullOrWhiteSpace(impersonation.Uid)) headers["Impersonate-Uid"] = new[] { impersonation.Uid! };
            if (impersonation.EffectiveGroups.Count > 0) headers["Impersonate-Group"] = impersonation.EffectiveGroups;
            foreach (var extra in impersonation.EffectiveExtra)
                headers["Impersonate-Extra-" + extra.Key] = extra.Value;
        }
        return headers.Count == 0 ? null : headers;
    }

    public static CancellationTokenSource? CreateTimeoutSource(TimeSpan? timeout, CancellationToken cancellationToken)
    {
        if (timeout is null || timeout <= TimeSpan.Zero) return null;
        CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(timeout.Value);
        return linked;
    }

    public static string? ResolveNamespace(KubeNamespaceScope scope, KubeTarget target, k8s.KubernetesClientConfiguration config) => scope.Kind switch
    {
        KubeNamespaceScopeKind.Explicit => scope.Name,
        KubeNamespaceScopeKind.Default => target.DefaultNamespace ?? config.Namespace ?? "default",
        KubeNamespaceScopeKind.All => null,
        KubeNamespaceScopeKind.Cluster => null,
        _ => null
    };
}
