using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;

namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlProtocolClient : IAsyncDisposable
{
    private readonly Stream _reader;
    private readonly Stream _writer;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly ConcurrentDictionary<ulong, TaskCompletionSource<WireProtocol.Frame>> _pending = new();
    private readonly ConcurrentDictionary<ulong, Channel<WireStreamItem>> _streams = new();
    private readonly CancellationTokenSource _readerCancellation = new();
    private readonly Task _readerTask;
    private long _nextCorrelation = 1;
    private int _disposed;

    private KubectlProtocolClient(Stream reader, Stream writer, WireHelloAck helloAck)
    {
        _reader = reader;
        _writer = writer;
        HelloAck = helloAck;
        _readerTask = Task.Run(ReadLoopAsync);
    }

    internal WireHelloAck HelloAck { get; }
    internal WireProtocol.Features Features => (WireProtocol.Features)HelloAck.FeatureBits;
    internal bool IsCompleted => _readerTask.IsCompleted;

    internal static async Task<KubectlProtocolClient> ConnectAsync(Stream reader, Stream writer, CancellationToken cancellationToken)
    {
        WireHello hello = new(WireProtocol.ProtocolMajor, WireProtocol.ProtocolMajor, "KubeShell.Kubectl", WireProtocol.ContractHash);
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(hello, WireProtocol.Json);
        await WireProtocol.WriteFrameAsync(writer, new WireProtocol.Frame(WireProtocol.MessageKind.Hello, 0, 1, payload), cancellationToken).ConfigureAwait(false);
        WireProtocol.Frame frame = await WireProtocol.ReadFrameAsync(reader, cancellationToken).ConfigureAwait(false);
        if (frame.CorrelationId != 1)
            throw new InvalidDataException("kubectl-host returned an unexpected handshake correlation id.");
        if (frame.Kind == WireProtocol.MessageKind.Error)
            throw new KubectlWireException(Deserialize<WireError>(frame.Payload));
        if (frame.Kind != WireProtocol.MessageKind.HelloAck)
            throw new InvalidDataException($"kubectl-host returned {frame.Kind} instead of HelloAck.");
        WireHelloAck ack = Deserialize<WireHelloAck>(frame.Payload);
        if (ack.Protocol != WireProtocol.ProtocolMajor)
            throw new InvalidDataException($"kubectl-host negotiated unsupported protocol {ack.Protocol}.");
        if (!string.Equals(ack.ContractHash, WireProtocol.ContractHash, StringComparison.Ordinal))
            throw new InvalidDataException("kubectl-host protocol contract fingerprint mismatch.");
        return new KubectlProtocolClient(reader, writer, ack);
    }

    internal Task<TResponse> RequestAsync<TRequest, TResponse>(
        WireProtocol.Method method,
        ulong sessionId,
        TRequest body,
        CancellationToken cancellationToken) =>
        RequestCoreAsync<TRequest, TResponse>(method, sessionId, body, cancellationToken, stream: null);

    internal async Task<KubectlProtocolStream<TResponse>> StartStreamAsync<TRequest, TResponse>(
        WireProtocol.Method method,
        ulong sessionId,
        TRequest body,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        ulong correlation = NextCorrelation();
        Channel<WireStreamItem> channel = Channel.CreateUnbounded<WireStreamItem>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = true,
            AllowSynchronousContinuations = false
        });
        if (!_streams.TryAdd(correlation, channel)) throw new InvalidOperationException("Duplicate IPC stream correlation id.");
        try
        {
            TResponse response = await RequestCoreAsync<TRequest, TResponse>(method, sessionId, body, cancellationToken, channel, correlation).ConfigureAwait(false);
            return new KubectlProtocolStream<TResponse>(this, correlation, response, channel.Reader);
        }
        catch
        {
            _streams.TryRemove(correlation, out _);
            channel.Writer.TryComplete();
            throw;
        }
    }

    internal async ValueTask CancelOperationAsync(ulong operationId, CancellationToken cancellationToken = default)
    {
        if (operationId == 0 || Volatile.Read(ref _disposed) != 0) return;
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new WireCancel(OperationId: operationId), WireProtocol.Json);
        await SendFrameAsync(new WireProtocol.Frame(WireProtocol.MessageKind.Cancel, 0, NextCorrelation(), payload), cancellationToken).ConfigureAwait(false);
    }

    private Task<TResponse> RequestCoreAsync<TRequest, TResponse>(
        WireProtocol.Method method,
        ulong sessionId,
        TRequest body,
        CancellationToken cancellationToken,
        Channel<WireStreamItem>? stream,
        ulong? fixedCorrelation = null)
    {
        return RequestCoreImplAsync<TRequest, TResponse>(method, sessionId, body, cancellationToken, stream, fixedCorrelation);
    }

    private async Task<TResponse> RequestCoreImplAsync<TRequest, TResponse>(
        WireProtocol.Method method,
        ulong sessionId,
        TRequest body,
        CancellationToken cancellationToken,
        Channel<WireStreamItem>? stream,
        ulong? fixedCorrelation)
    {
        ThrowIfDisposed();
        ulong correlation = fixedCorrelation ?? NextCorrelation();
        TaskCompletionSource<WireProtocol.Frame> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(correlation, completion)) throw new InvalidOperationException("Duplicate IPC correlation id.");

        JsonElement bodyElement = JsonSerializer.SerializeToElement(body, WireProtocol.Json);
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new WireRequest(method, sessionId, bodyElement), WireProtocol.Json);
        try
        {
            await SendFrameAsync(new WireProtocol.Frame(WireProtocol.MessageKind.Request, 0, correlation, payload), cancellationToken).ConfigureAwait(false);
            using CancellationTokenRegistration registration = cancellationToken.Register(static state =>
            {
                var tuple = ((KubectlProtocolClient Client, ulong Correlation))state!;
                _ = tuple.Client.CancelCorrelationBestEffortAsync(tuple.Correlation);
            }, (this, correlation));

            WireProtocol.Frame frame = await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            if (frame.Kind == WireProtocol.MessageKind.Error)
                throw new KubectlWireException(Deserialize<WireError>(frame.Payload));
            if (frame.Kind != WireProtocol.MessageKind.Response)
                throw new InvalidDataException($"Unexpected kubectl-host response frame {frame.Kind}.");
            WireResponse envelope = Deserialize<WireResponse>(frame.Payload);
            if (envelope.Body is null) return default!;
            TResponse? response = envelope.Body.Value.Deserialize<TResponse>(WireProtocol.Json);
            return response ?? throw new InvalidDataException("kubectl-host returned an empty response body.");
        }
        finally
        {
            _pending.TryRemove(correlation, out _);
        }
    }

    private async Task CancelCorrelationBestEffortAsync(ulong correlation)
    {
        try
        {
            if (Volatile.Read(ref _disposed) != 0) return;
            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new WireCancel(CorrelationId: correlation), WireProtocol.Json);
            await SendFrameAsync(new WireProtocol.Frame(WireProtocol.MessageKind.Cancel, 0, NextCorrelation(), payload), CancellationToken.None).ConfigureAwait(false);
        }
        catch { }
    }

    private async Task SendFrameAsync(WireProtocol.Frame frame, CancellationToken cancellationToken)
    {
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await WireProtocol.WriteFrameAsync(_writer, frame, cancellationToken).ConfigureAwait(false); }
        finally { _writeGate.Release(); }
    }

    private async Task ReadLoopAsync()
    {
        Exception? terminal = null;
        try
        {
            while (!_readerCancellation.IsCancellationRequested)
            {
                WireProtocol.Frame frame = await WireProtocol.ReadFrameAsync(_reader, _readerCancellation.Token).ConfigureAwait(false);
                switch (frame.Kind)
                {
                    case WireProtocol.MessageKind.Response:
                    case WireProtocol.MessageKind.Error:
                        if (_pending.TryGetValue(frame.CorrelationId, out TaskCompletionSource<WireProtocol.Frame>? completion))
                            completion.TrySetResult(frame);
                        break;
                    case WireProtocol.MessageKind.StreamItem:
                        if (_streams.TryGetValue(frame.CorrelationId, out Channel<WireStreamItem>? channel))
                            await channel.Writer.WriteAsync(Deserialize<WireStreamItem>(frame.Payload), _readerCancellation.Token).ConfigureAwait(false);
                        break;
                    case WireProtocol.MessageKind.StreamEnd:
                        if (_streams.TryRemove(frame.CorrelationId, out Channel<WireStreamItem>? ended))
                        {
                            WireStreamEnd end = Deserialize<WireStreamEnd>(frame.Payload);
                            if (end.Error is not null)
                                ended.Writer.TryWrite(new WireStreamItem(end.OperationId, "error", null, end.Error, null));
                            ended.Writer.TryComplete();
                        }
                        break;
                    case WireProtocol.MessageKind.Pong:
                        break;
                    default:
                        throw new InvalidDataException($"Unexpected asynchronous kubectl-host frame {frame.Kind}.");
                }
            }
        }
        catch (OperationCanceledException) when (_readerCancellation.IsCancellationRequested) { }
        catch (Exception ex) { terminal = ex; }
        finally
        {
            terminal ??= new EndOfStreamException("kubectl-host IPC connection closed.");
            foreach (TaskCompletionSource<WireProtocol.Frame> pending in _pending.Values) pending.TrySetException(terminal);
            WireError streamError = new("unavailable", "kubectl-host.disconnected", terminal.Message);
            foreach (Channel<WireStreamItem> stream in _streams.Values)
            {
                stream.Writer.TryWrite(new WireStreamItem(0, "error", null, streamError, null));
                stream.Writer.TryComplete();
            }
            _pending.Clear();
            _streams.Clear();
        }
    }

    internal void ForgetStream(ulong correlationId)
    {
        if (_streams.TryRemove(correlationId, out Channel<WireStreamItem>? channel)) channel.Writer.TryComplete();
    }

    private ulong NextCorrelation() => unchecked((ulong)Interlocked.Increment(ref _nextCorrelation));
    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    private static T Deserialize<T>(byte[] payload) => JsonSerializer.Deserialize<T>(payload, WireProtocol.Json) ?? throw new InvalidDataException($"Cannot deserialize kubectl-host {typeof(T).Name} payload.");

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        try { await SendFrameAsync(new WireProtocol.Frame(WireProtocol.MessageKind.Shutdown, 0, NextCorrelation(), Array.Empty<byte>()), CancellationToken.None).ConfigureAwait(false); }
        catch { }
        _readerCancellation.Cancel();
        try { await _readerTask.WaitAsync(TimeSpan.FromSeconds(1)).ConfigureAwait(false); } catch { }
        _readerCancellation.Dispose();
        _writeGate.Dispose();
    }
}

internal sealed class KubectlProtocolStream<TResponse> : IAsyncDisposable
{
    private readonly KubectlProtocolClient _client;
    private readonly ulong _correlationId;
    private int _disposed;

    internal KubectlProtocolStream(KubectlProtocolClient client, ulong correlationId, TResponse response, ChannelReader<WireStreamItem> reader)
    {
        _client = client;
        _correlationId = correlationId;
        Response = response;
        Reader = reader;
    }

    internal TResponse Response { get; }
    internal ChannelReader<WireStreamItem> Reader { get; }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) _client.ForgetStream(_correlationId);
        return ValueTask.CompletedTask;
    }
}
