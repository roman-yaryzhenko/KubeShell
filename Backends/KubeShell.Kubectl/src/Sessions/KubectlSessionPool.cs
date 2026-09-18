using System.Collections.Concurrent;
using KubeShell.Runtime;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlSessionPool
{
    private readonly KubectlHostProcess _host;
    private readonly ConcurrentDictionary<SessionKey, Lazy<Task<KubectlSession>>> _sessions = new();

    internal KubectlSessionPool(KubectlHostProcess host) => _host = host;

    internal async Task<KubectlSession> GetAsync(KubeTarget target, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(target);
        KubectlHostConnection connection = await _host.GetConnectionAsync(cancellationToken).ConfigureAwait(false);
        RemoveStaleGenerations(connection.Generation);
        SessionKey key = SessionKey.Create(target, connection.Generation);
        Lazy<Task<KubectlSession>> lazy = _sessions.GetOrAdd(key, _ => new Lazy<Task<KubectlSession>>(
            () => CreateAsync(connection, target), LazyThreadSafetyMode.ExecutionAndPublication));
        try { return await lazy.Value.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch
        {
            _sessions.TryRemove(key, out _);
            throw;
        }
    }

    private void RemoveStaleGenerations(long currentGeneration)
    {
        foreach (SessionKey key in _sessions.Keys)
        {
            // Sessions belong to one helper-process generation. Once that process has gone away,
            // retaining completed Lazy<Task<...>> entries serves no recovery purpose.
            if (key.Generation != currentGeneration) _sessions.TryRemove(key, out _);
        }
    }

    private static async Task<KubectlSession> CreateAsync(KubectlHostConnection connection, KubeTarget target)
    {
        WireSessionCreateRequest request = new(target.KubeConfigPaths, target.Context, target.DefaultNamespace);
        WireSessionCreateResponse response = await connection.Client.RequestAsync<WireSessionCreateRequest, WireSessionCreateResponse>(
            WireProtocol.Method.SessionCreate, 0, request, CancellationToken.None).ConfigureAwait(false);
        return new KubectlSession(connection.Client, connection.Generation, response.SessionId);
    }

    private sealed record SessionKey(long Generation, string DefaultNamespace, string TargetIdentity)
    {
        internal static SessionKey Create(KubeTarget target, long generation) => new(
            generation,
            target.DefaultNamespace ?? string.Empty,
            KubeTargetIdentityEncoding.Create(target));
    }
}

internal readonly record struct KubectlSession(KubectlProtocolClient Client, long Generation, ulong Id);
