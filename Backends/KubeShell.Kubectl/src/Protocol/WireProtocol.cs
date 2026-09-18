using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KubeShell.Backends.Kubectl;

internal static class WireProtocol
{
    internal const uint Magic = 0x4b534831; // KSH1
    internal const ushort ProtocolMajor = 1;
    internal const ushort ProtocolMinor = 0;
    internal const int HeaderSize = 24;
    internal const int MaxPayload = 64 << 20;
    internal const string ContractHash = "859ffcd280d7e1290372c32b5b220682423ee19459375f3663dd871d53aa7fde";

    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    internal enum MessageKind : ushort
    {
        Hello = 1,
        HelloAck,
        Request,
        Response,
        Error,
        StreamItem,
        StreamEnd,
        Cancel,
        Shutdown,
        Ping,
        Pong
    }

    internal enum Method : uint
    {
        SessionCreate = 1,
        SessionClose = 2,
        DiscoverApiVersion = 3,
        ResolveResource = 4,
        DiscoverPreferred = 5,
        Get = 100,
        List = 101,
        Create = 102,
        Replace = 103,
        Delete = 104,
        Patch = 105,
        Apply = 106,
        WatchStart = 107,
        LogsStart = 108,
        Explain = 200,
        RolloutUndo = 201,
        RolloutRestart = 202,
        Scale = 203,
        SetImage = 204,
        RolloutStatus = 205,
        ConfigView = 300,
        AccessReview = 400,
        PodMetrics = 401,
        NodeMetrics = 402,
        DnsProbe = 403,
        Copy = 500,
        Debug = 600
    }

    [Flags]
    internal enum Features : ulong
    {
        Discovery = 1UL << 0,
        Crud = 1UL << 1,
        ClientPreview = 1UL << 2,
        ServerPreview = 1UL << 3,
        ClientSideApply = 1UL << 4,
        ServerSideApply = 1UL << 5,
        Watch = 1UL << 6,
        Subresources = 1UL << 7,
        Impersonation = 1UL << 8,
        FieldValidation = 1UL << 9,
        Schema = 1UL << 10,
        RolloutUndo = 1UL << 11,
        Workloads = 1UL << 12,
        Diagnostics = 1UL << 13,
        Logs = 1UL << 14,
        Copy = 1UL << 15,
        Debug = 1UL << 16
    }

    internal sealed record Frame(MessageKind Kind, uint Flags, ulong CorrelationId, byte[] Payload);

    internal static async ValueTask<Frame> ReadFrameAsync(Stream stream, CancellationToken cancellationToken)
    {
        byte[] header = new byte[HeaderSize];
        await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false);
        if (BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0, 4)) != Magic)
            throw new InvalidDataException("Invalid KubeShell kubectl-host IPC magic.");
        ushort major = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(4, 2));
        if (major != ProtocolMajor)
            throw new InvalidDataException($"Unsupported kubectl-host protocol major {major}.");

        MessageKind kind = (MessageKind)BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(8, 2));
        uint flags = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(10, 4));
        ulong correlation = BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(14, 8));
        uint length = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(22, 2));
        if (length == 0xffff)
        {
            byte[] extended = new byte[4];
            await ReadExactlyAsync(stream, extended, cancellationToken).ConfigureAwait(false);
            length = BinaryPrimitives.ReadUInt32LittleEndian(extended);
        }
        if (length > MaxPayload)
            throw new InvalidDataException($"kubectl-host payload length {length} exceeds the protocol limit.");
        byte[] payload = new byte[checked((int)length)];
        if (length != 0) await ReadExactlyAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        return new Frame(kind, flags, correlation, payload);
    }

    internal static async ValueTask WriteFrameAsync(Stream stream, Frame frame, CancellationToken cancellationToken)
    {
        if (frame.Payload.Length > MaxPayload)
            throw new InvalidDataException($"kubectl-host payload length {frame.Payload.Length} exceeds the protocol limit.");
        byte[] header = new byte[HeaderSize];
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0, 4), Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(4, 2), ProtocolMajor);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(6, 2), ProtocolMinor);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(8, 2), (ushort)frame.Kind);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(10, 4), frame.Flags);
        BinaryPrimitives.WriteUInt64LittleEndian(header.AsSpan(14, 8), frame.CorrelationId);

        if (frame.Payload.Length < 0xffff)
        {
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(22, 2), (ushort)frame.Payload.Length);
            await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(22, 2), 0xffff);
            await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
            byte[] extended = new byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(extended, (uint)frame.Payload.Length);
            await stream.WriteAsync(extended, cancellationToken).ConfigureAwait(false);
        }
        if (frame.Payload.Length != 0) await stream.WriteAsync(frame.Payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async ValueTask ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken cancellationToken)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int read = await stream.ReadAsync(buffer[offset..], cancellationToken).ConfigureAwait(false);
            if (read == 0) throw new EndOfStreamException("kubectl-host IPC stream ended unexpectedly.");
            offset += read;
        }
    }
}
