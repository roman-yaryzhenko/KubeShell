using System;
using System.Collections.Generic;

namespace KubeShell.Runtime;

public enum KubeFieldValidationMode
{
    Default,
    Ignore,
    Warn,
    Strict
}

public sealed record KubeImpersonation(
    string? User = null,
    string? Uid = null,
    IReadOnlyList<string>? Groups = null,
    IReadOnlyDictionary<string, IReadOnlyList<string>>? Extra = null)
{
    public IReadOnlyList<string> EffectiveGroups => Groups ?? Array.Empty<string>();
    public IReadOnlyDictionary<string, IReadOnlyList<string>> EffectiveExtra =>
        Extra ?? EmptyExtra;

    private static IReadOnlyDictionary<string, IReadOnlyList<string>> EmptyExtra { get; } =
        new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
}

/// <summary>
/// Per-operation execution settings. These are deliberately separate from KubeTarget.
/// CorrelationId is best-effort observability metadata: an adapter may omit it when the underlying
/// transport cannot carry custom correlation metadata without changing operation semantics.
/// </summary>
public sealed record KubeExecutionContext(
    KubeImpersonation? Impersonation = null,
    TimeSpan? Timeout = null,
    string? UserAgent = null,
    KubeFieldValidationMode FieldValidation = KubeFieldValidationMode.Default,
    string? CorrelationId = null)
{
    public static KubeExecutionContext Default { get; } = new();
}
