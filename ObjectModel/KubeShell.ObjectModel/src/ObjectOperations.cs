using System;
using System.Collections.Generic;

namespace KubeShell.ObjectModel;

public enum ObjectOperationCardinality
{
    Single,
    Multiple
}

public enum ObjectOperationAvailability
{
    Available,
    Unavailable,
    Unsupported
}

public sealed record ObjectOperationParameterDescriptor(
    string Name,
    Type ParameterType,
    bool Required = false,
    bool Sensitive = false,
    object? DefaultValue = null);

public sealed record ObjectOperationVariantDescriptor(
    string Id,
    string DisplayName,
    IReadOnlyList<ObjectOperationParameterDescriptor> Parameters);

public sealed record ObjectOperationDescriptor(
    string Id,
    string DisplayName,
    ObjectOperationCardinality Cardinality,
    ObjectOperationAvailability Availability,
    IReadOnlyList<ObjectOperationVariantDescriptor>? Variants = null,
    string? Reason = null);

public sealed record ObjectOperationRequest(
    string OperationId,
    IReadOnlyList<KubeNodeLocator> Targets,
    IReadOnlyDictionary<string, object?>? Parameters = null);

public sealed record ObjectOperationMessage(string Message, bool Warning = false, string? Code = null);
public sealed record ObjectChangeSummary(string? Description = null, int Changed = 0, int Added = 0, int Removed = 0);
public sealed record ObjectOperationResult(
    IReadOnlyList<KubeNavigationNode> Values,
    IReadOnlyList<ObjectOperationMessage> Messages,
    ObjectChangeSummary? Change = null);
