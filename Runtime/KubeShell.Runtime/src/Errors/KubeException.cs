using System;
using System.Collections.Generic;

namespace KubeShell.Runtime;

public enum KubeErrorKind
{
    Transport,
    NotFound,
    InvalidResource,
    Configuration,
    Serialization,
    Authentication,
    Authorization,
    Conflict,
    Unsupported,
    Unavailable,
    Cancelled,
    Indeterminate
}

/// <summary>
/// Backend-neutral error value. HTTP status codes, process exit codes and stderr belong to adapters
/// and may be surfaced as diagnostics without becoming part of the Runtime error contract.
/// </summary>
public sealed record KubeError(
    KubeErrorKind Kind,
    string Message,
    string? Code = null,
    ResourceIdentity? Resource = null);

public sealed class KubeException : Exception
{
    public KubeException(
        KubeErrorKind kind,
        string message,
        Exception? innerException = null,
        ResourceIdentity? resource = null,
        KubeTarget? target = null,
        string? code = null,
        IReadOnlyList<KubeWarning>? warnings = null,
        IReadOnlyList<KubeDiagnostic>? diagnostics = null)
        : base(message, innerException)
    {
        Kind = kind;
        Resource = resource;
        Target = target;
        Code = code;
        Warnings = warnings ?? Array.Empty<KubeWarning>();
        Diagnostics = diagnostics ?? Array.Empty<KubeDiagnostic>();
    }

    public KubeErrorKind Kind { get; }
    public ResourceIdentity? Resource { get; }
    public KubeTarget? Target { get; }
    public string? Code { get; }
    public IReadOnlyList<KubeWarning> Warnings { get; }
    public IReadOnlyList<KubeDiagnostic> Diagnostics { get; }
    public KubeError Error => new(Kind, Message, Code, Resource);
}
