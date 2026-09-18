using System.Text.Json;

namespace KubeShell.Backends.Kubectl;

internal sealed record WireHello(ushort MinProtocol, ushort MaxProtocol, string Client, string ContractHash);
internal sealed record WireHelloAck(ushort Protocol, ulong FeatureBits, string BuildVersion, string KubectlVersion, string ClientGoVersion, string ContractHash);
internal sealed record WireRequest(WireProtocol.Method Method, ulong SessionId, JsonElement? Body);
internal sealed record WireResponse(JsonElement? Body);
internal sealed record WireCancel(ulong CorrelationId = 0, ulong OperationId = 0);
internal sealed record WireError(string Class, string Code, string Message, int HttpStatus = 0, bool? Retryable = null, JsonElement? Status = null, Dictionary<string, string>? Diagnostics = null);

internal sealed record WireSessionCreateRequest(string[] KubeconfigPaths, string? Context, string? DefaultNamespace);
internal sealed record WireSessionCreateResponse(ulong SessionId);
internal sealed record WireSessionCloseRequest(ulong SessionId);

internal sealed record WireNamespaceScope(string Kind, string? Name = null);
internal sealed record WireGvr(string? Group, string? Version, string Resource);
internal sealed record WireResourceRef(WireGvr Gvr, string? Name, WireNamespaceScope Namespace, string? Subresource = null);
internal sealed record WireQuery(WireGvr Gvr, string? Name, WireNamespaceScope Namespace, string? LabelSelector, string? FieldSelector, string? Subresource = null);
internal sealed record WireImpersonation(string? User, string? Uid, string[] Groups, Dictionary<string, string[]> Extra);
internal sealed record WireExecutionContext(long TimeoutMilliseconds, string? UserAgent, string? FieldValidation, string? CorrelationId, WireImpersonation? Impersonation);
internal sealed record WireConcurrency(string? Mode, string? ExpectedResourceVersion);
internal sealed record WireOperationRequest(
    WireResourceRef? Resource,
    WireQuery? Query,
    WireExecutionContext Execution,
    JsonElement? Payload = null,
    string? Preview = null,
    string? ApplyStrategy = null,
    string? PatchType = null,
    string? FieldManager = null,
    bool ForceConflicts = false,
    bool Force = false,
    long? GracePeriodSeconds = null,
    WireConcurrency? Concurrency = null,
    string? ResourceVersion = null,
    bool AllowBookmarks = true,
    long ToRevision = 0,
    int? Replicas = null,
    string? Container = null,
    string? Image = null,
    long WaitTimeoutMilliseconds = 0,
    long Revision = 0);

internal sealed record WireResourceResult(WireGvr Gvr, JsonElement Json);
internal sealed record WireOperationResponse(WireResourceResult[]? Resources, string[]? Warnings, Dictionary<string, string>? Diagnostics, ulong OperationId = 0);
internal sealed record WireDiscoverRequest(string? ApiVersion, WireGvr? Resource, bool Refresh, WireExecutionContext Execution);
internal sealed record WireSubresourceDescriptor(string Name, string? Group, string? Version, string? Kind, bool Namespaced, string[]? Verbs);
internal sealed record WireResourceDescriptor(WireGvr Gvr, string? Kind, bool Namespaced, string[]? Verbs, string? SingularName, string[]? ShortNames, string[]? Categories, WireSubresourceDescriptor[]? Subresources);
internal sealed record WireDiscoverResponse(WireResourceDescriptor[]? Resources);
internal sealed record WireStreamItem(ulong OperationId, string EventType, WireResourceResult? Resource, WireError? Error, string? ResourceVersion, string? Text = null);
internal sealed record WireStreamEnd(ulong OperationId, WireError? Error);

internal sealed record WireSchemaRequest(WireGvr Resource, string? FieldPath, bool Recursive, int MaxDepth, WireExecutionContext Execution);
internal sealed record WireSchemaField(string Name, string Path, string? Type, string? Format, string? Description, bool Required, string[]? Enum, WireSchemaField[]? Children);
internal sealed record WireSchemaResponse(WireGvr Gvr, string? Kind, string? FieldPath, string? Type, string? Format, string? Description, WireSchemaField[]? Fields);

internal sealed record WireConfigContext(string Name, string? Cluster, string? User, string? Namespace);
internal sealed record WireConfigViewResponse(string? CurrentContext, WireConfigContext[]? Contexts);

internal sealed record WireAccessReviewRequest(string Verb, string Resource, string? Name, string? Namespace, string? Group, string? Subresource, bool Namespaced, string? AsUser, string[]? AsGroups, WireExecutionContext Execution);
internal sealed record WireAccessReviewResponse(bool Allowed, bool Denied, string? Reason, string? EvaluationError);
internal sealed record WireMetricsRequest(string? Namespace, WireExecutionContext Execution);
internal sealed record WireMetricsResponse(string Json);
internal sealed record WireDnsProbeRequest(string Namespace, string Name, string Image, long TimeoutMilliseconds, WireExecutionContext Execution);
internal sealed record WireDnsProbeResponse(bool Success, string Output);

internal sealed record WireLogRequest(string Pod, WireNamespaceScope Namespace, string? Container, long TailLines, long SinceSeconds, bool Previous, bool Follow, bool Timestamps, bool Prefix, WireExecutionContext Execution);

internal sealed record WireCopyRequest(string Pod, WireNamespaceScope Namespace, string LocalPath, string RemotePath, bool ToPod, string? Container, WireExecutionContext Execution);
internal sealed record WireCopyResponse(string? Output, string? ErrorOutput);

internal sealed record WireDebugRequest(
    WireResourceRef Target, string? Image, string[] Command, bool ArgumentsOnly, bool? Attach, string? Container,
    string? CopyTo, bool Replace, Dictionary<string, string>? Environment, bool Interactive, bool Tty, bool Quiet,
    bool KeepLabels, bool KeepAnnotations, bool KeepLiveness, bool KeepReadiness, bool KeepStartup, bool? KeepInitContainers,
    bool SameNode, Dictionary<string, string>? SetImages, bool? ShareProcesses, string? TargetContainer, string Profile,
    string? CustomProfileJson, string? ImagePullPolicy, WireExecutionContext Execution);
internal sealed record WireDebugAttachment(string Namespace, string Pod, string Container, string Continuation, bool Interactive, bool Tty, bool Quiet);
internal sealed record WireDebugResponse(WireResourceResult? Resource, WireDebugAttachment? Attachment, string[]? Warnings, string? Output);
