using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

public sealed record KubeSchemaField(
    string Name,
    string Path,
    string? Type = null,
    string? Format = null,
    string? Description = null,
    bool Required = false,
    IReadOnlyList<string>? Enum = null,
    IReadOnlyList<KubeSchemaField>? Children = null)
{
    public IReadOnlyList<string> EnumValues { get; init; } = Enum ?? Array.Empty<string>();
    public IReadOnlyList<KubeSchemaField> Fields { get; init; } = Children ?? Array.Empty<KubeSchemaField>();
}

public sealed record KubeSchemaDocument(
    GroupVersionResource Gvr,
    string? Kind,
    string? FieldPath,
    string? Type,
    string? Format,
    string? Description,
    IReadOnlyList<KubeSchemaField> Fields);

public sealed record KubeSchemaRequest(
    GroupVersionResource Resource,
    string? FieldPath = null,
    bool Recursive = false,
    int MaxDepth = 0);

public interface IKubeSchemaBackend
{
    ValueTask<KubeSchemaDocument> GetSchemaAsync(
        KubeSchemaRequest request,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default);
}

public interface IKubeSchemaClient
{
    KubeSchemaDocument GetSchema(
        KubeTarget target,
        KubeSchemaRequest request,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Routes schema requests to a backend that can inspect the server OpenAPI document. Runtime returns
/// a neutral schema tree rather than kubectl's plaintext so formatting, completion and future TUI
/// consumers share one representation.
/// </summary>
public sealed class KubeSchemaClient : IKubeSchemaClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeSchemaClient(IKubeBackendSelector selector) => _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeSchemaClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public KubeSchemaDocument GetSchema(
        KubeTarget target,
        KubeSchemaRequest request,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(request);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        IKubeSchemaBackend backend = _selector.SelectCapabilityAsync(
            new KubeSchemaCapabilityRequest(request), target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
        return backend.GetSchemaAsync(request, target, context, cancellationToken).AsTask().GetAwaiter().GetResult();
    }
}
