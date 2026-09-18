using System.Collections.Concurrent;
using System.Diagnostics;

namespace KubeShell.Backends.Kubectl;

public sealed class KubectlHostOptions
{
    public string? HostPath { get; init; }
    public TimeSpan StartupTimeout { get; init; } = TimeSpan.FromSeconds(15);
}

internal sealed class KubectlHostProcess : IAsyncDisposable
{
    private readonly KubectlHostOptions _options;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly ConcurrentQueue<string> _stderr = new();
    private Process? _process;
    private KubectlProtocolClient? _client;
    private Task? _stderrPump;
    private long _generation;
    private int _disposed;

    internal KubectlHostProcess(KubectlHostOptions? options = null) => _options = options ?? new KubectlHostOptions();

    internal async Task<KubectlHostConnection> GetConnectionAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_process is { HasExited: false } && _client is not null && !_client.IsCompleted)
                return new KubectlHostConnection(_client, _generation);
            await StopCurrentAsync().ConfigureAwait(false);
            return await StartAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    internal IReadOnlyList<string> StderrSnapshot() => _stderr.ToArray();

    private async Task<KubectlHostConnection> StartAsync(CancellationToken cancellationToken)
    {
        string executable = KubectlHostLocator.Resolve(_options.HostPath);
        ProcessStartInfo start = new()
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add("--transport=stdio");
        Process process = Process.Start(start) ?? throw new InvalidOperationException($"Failed to start kubectl host '{executable}'.");
        _process = process;
        _stderrPump = PumpStderrAsync(process);

        using CancellationTokenSource startup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        startup.CancelAfter(_options.StartupTimeout);
        try
        {
            _client = await KubectlProtocolClient.ConnectAsync(process.StandardOutput.BaseStream, process.StandardInput.BaseStream, startup.Token).ConfigureAwait(false);
            _generation = checked(_generation + 1);
            return new KubectlHostConnection(_client, _generation);
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            await StopCurrentAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async Task PumpStderrAsync(Process process)
    {
        try
        {
            while (true)
            {
                string? line = await process.StandardError.ReadLineAsync().ConfigureAwait(false);
                if (line is null) return;
                _stderr.Enqueue(line);
                while (_stderr.Count > 128 && _stderr.TryDequeue(out _)) { }
            }
        }
        catch { }
    }

    private async Task StopCurrentAsync()
    {
        KubectlProtocolClient? client = _client;
        _client = null;
        if (client is not null)
        {
            try { await client.DisposeAsync().ConfigureAwait(false); } catch { }
        }

        Process? process = _process;
        _process = null;
        if (process is not null)
        {
            try
            {
                if (!process.HasExited)
                {
                    if (!process.WaitForExit(1000)) process.Kill(entireProcessTree: true);
                }
            }
            catch { }
            process.Dispose();
        }
        if (_stderrPump is not null)
        {
            try { await _stderrPump.ConfigureAwait(false); } catch { }
            _stderrPump = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        await _gate.WaitAsync().ConfigureAwait(false);
        try { await StopCurrentAsync().ConfigureAwait(false); }
        finally { _gate.Release(); _gate.Dispose(); }
    }
}

internal readonly record struct KubectlHostConnection(KubectlProtocolClient Client, long Generation);
