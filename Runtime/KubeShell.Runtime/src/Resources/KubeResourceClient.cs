using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace KubeShell.Runtime;

/// <summary>
/// Low-level semantic operation port. Consumers that only need CRUD-style resource access should
/// depend on IKubeResourceClient or IKubeResourceExecutionClient instead of learning about routing.
/// </summary>
public interface IKubeOperationClient
{
    KubeOperationSupport Evaluate(KubeTarget target, KubeOperation operation, KubeExecutionContext? executionContext = null);
    KubeOperationResult Execute(KubeTarget target, KubeOperation operation, KubeExecutionContext? executionContext = null);
    ValueTask<KubeOperationSupport> EvaluateAsync(KubeTarget target, KubeOperation operation, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeOperationResult> ExecuteAsync(KubeTarget target, KubeOperation operation, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
}

/// <summary>Frontend-neutral execution envelope. Infrastructure/backend details never cross this port.</summary>
public sealed record KubeExecutionResult<T>(
    T Value,
    IReadOnlyList<KubeWarning> Warnings,
    IReadOnlyList<KubeDiagnostic> Diagnostics);

/// <summary>Execution envelope for semantic operations that do not return a value.</summary>
public sealed record KubeExecutionResult(
    IReadOnlyList<KubeWarning> Warnings,
    IReadOnlyList<KubeDiagnostic> Diagnostics);

/// <summary>
/// Rich resource-oriented semantic port for frontends that need warnings and diagnostics in addition
/// to the resource value. Routing remains behind IKubeOperationClient and is never exposed here.
/// </summary>
public interface IKubeResourceExecutionClient
{
    ValueTask<KubeExecutionResult<IReadOnlyList<KubeResource>>> GetAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult<KubeResource>> CreateAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult<KubeResource>> ReplaceAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult<KubeResource>> ApplyAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult<KubeResource>> PatchAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeExecutionResult> DeleteAsync(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
}

/// <summary>
/// Narrow resource-oriented facade shared by shell and simple query call sites. It deliberately
/// unwraps rich execution envelopes so callers that do not need diagnostics stay simple.
/// </summary>
public interface IKubeResourceClient
{
    IReadOnlyList<KubeResource> Get(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null);
    bool Exists(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null);
    KubeResource? TryGet(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null);
    IReadOnlyList<string> ListNames(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null);
    KubeResource Create(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null);
    KubeResource Replace(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null);
    KubeResource Apply(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null);
    KubeResource Patch(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null);
    void Delete(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null);

    ValueTask<IReadOnlyList<KubeResource>> GetAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<bool> ExistsAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeResource?> TryGetAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<IReadOnlyList<string>> ListNamesAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeResource> CreateAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeResource> ReplaceAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeResource> ApplyAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask<KubeResource> PatchAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
    ValueTask DeleteAsync(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default);
}

/// <summary>
/// Semantics-preserving operation client. Backend ordering is preference only; a selected execution
/// is never replayed through another backend after execution starts.
/// </summary>
public sealed class KubeOperationClient : IKubeOperationClient
{
    private readonly IKubeBackendSelector _selector;

    public KubeOperationClient(IKubeBackendSelector selector) =>
        _selector = selector ?? throw new ArgumentNullException(nameof(selector));

    public KubeOperationClient(IKubeBackend backend) : this(new KubeBackendRouter(new[] { backend })) { }
    public KubeOperationClient(IEnumerable<IKubeBackend> backends) : this(new KubeBackendRouter(backends)) { }

    public KubeOperationSupport Evaluate(KubeTarget target, KubeOperation operation, KubeExecutionContext? executionContext = null) =>
        EvaluateAsync(target, operation, executionContext).GetAwaiter().GetResult();

    public KubeOperationResult Execute(KubeTarget target, KubeOperation operation, KubeExecutionContext? executionContext = null) =>
        ExecuteAsync(target, operation, executionContext).GetAwaiter().GetResult();

    public async ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeTarget target,
        KubeOperation operation,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(operation);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        try
        {
            return await _selector.EvaluateOperationAsync(operation, target, context, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex)
        {
            throw RuntimeCancellation(ex, target, "runtime.operation.cancelled", "Kubernetes operation evaluation was cancelled.");
        }
    }

    public async ValueTask<KubeOperationResult> ExecuteAsync(
        KubeTarget target,
        KubeOperation operation,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(operation);
        KubeExecutionContext context = executionContext ?? KubeExecutionContext.Default;
        try
        {
            IKubeBackend backend = await _selector.SelectOperationAsync(operation, target, context, cancellationToken).ConfigureAwait(false);
            return await backend.ExecuteAsync(operation, target, context, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException ex)
        {
            throw RuntimeCancellation(ex, target, "runtime.operation.cancelled", "Kubernetes operation was cancelled.");
        }
    }

    private static KubeException RuntimeCancellation(OperationCanceledException exception, KubeTarget target, string code, string message) =>
        new(KubeErrorKind.Cancelled, message, exception, target: target, code: code);
}

/// <summary>
/// Single rich execution implementation for CRUD semantics. Both rich and narrow facades reuse this
/// implementation so validation, serialization and routing rules have one source of truth.
/// </summary>
public sealed class KubeResourceExecutionClient : IKubeResourceExecutionClient
{
    private readonly IKubeOperationClient _operations;

    public KubeResourceExecutionClient(IKubeOperationClient operations) =>
        _operations = operations ?? throw new ArgumentNullException(nameof(operations));

    public KubeResourceExecutionClient(IKubeBackend backend) : this(new KubeOperationClient(backend)) { }
    public KubeResourceExecutionClient(IEnumerable<IKubeBackend> backends) : this(new KubeOperationClient(backends)) { }
    public KubeResourceExecutionClient(IKubeBackendSelector selector) : this(new KubeOperationClient(selector)) { }

    public async ValueTask<KubeExecutionResult<IReadOnlyList<KubeResource>>> GetAsync(
        KubeTarget target,
        ResourceQuery query,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateQuery(target, query);
        KubeOperation operation = string.IsNullOrWhiteSpace(query.Name)
            ? new KubeListOperation(query)
            : new KubeGetOperation(query.ToIdentity(target));
        KubeOperationResult result = await _operations.ExecuteAsync(target, operation, executionContext, cancellationToken).ConfigureAwait(false);
        return new KubeExecutionResult<IReadOnlyList<KubeResource>>(result.Resources, result.Warnings, result.Diagnostics);
    }

    public async ValueTask<KubeExecutionResult<KubeResource>> CreateAsync(
        KubeTarget target,
        ResourceIdentity identity,
        string payloadJson,
        KubeCreateOptions? options = null,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateMutation(target, identity, payloadJson);
        KubeWireSerializer.ValidateIdentity(payloadJson, identity, target);
        KubeOperationResult result = await _operations.ExecuteAsync(
            target,
            new KubeCreateOperation(identity, payloadJson, options ?? new KubeCreateOptions()),
            executionContext,
            cancellationToken).ConfigureAwait(false);
        return ResourceValidation.RequireResource(result, "Create", identity, target);
    }

    public async ValueTask<KubeExecutionResult<KubeResource>> ReplaceAsync(
        KubeTarget target,
        ResourceIdentity identity,
        string payloadJson,
        KubeReplaceOptions? options = null,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateMutation(target, identity, payloadJson);
        ResourceValidation.ValidateConcurrency(options?.Concurrency, identity, target);
        KubeWireSerializer.ValidateIdentity(payloadJson, identity, target);
        KubeOperationResult result = await _operations.ExecuteAsync(
            target,
            new KubeReplaceOperation(identity, payloadJson, options ?? new KubeReplaceOptions()),
            executionContext,
            cancellationToken).ConfigureAwait(false);
        return ResourceValidation.RequireResource(result, "Replace", identity, target);
    }

    public async ValueTask<KubeExecutionResult<KubeResource>> ApplyAsync(
        KubeTarget target,
        ResourceIdentity identity,
        string payloadJson,
        KubeApplyOptions? options = null,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateMutation(target, identity, payloadJson);
        string wire = KubeWireSerializer.PrepareApplyJson(payloadJson);
        KubeWireSerializer.ValidateIdentity(wire, identity, target);
        KubeOperationResult result = await _operations.ExecuteAsync(
            target,
            new KubeApplyOperation(identity, wire, options ?? new KubeApplyOptions()),
            executionContext,
            cancellationToken).ConfigureAwait(false);
        return ResourceValidation.RequireResource(result, "Apply", identity, target);
    }

    public async ValueTask<KubeExecutionResult<KubeResource>> PatchAsync(
        KubeTarget target,
        ResourceIdentity identity,
        string payloadJson,
        KubePatchOptions? options = null,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateMutation(target, identity, payloadJson);
        ResourceValidation.ValidateConcurrency(options?.Concurrency, identity, target);
        KubeWireSerializer.ValidateJson(payloadJson, identity);
        KubeOperationResult result = await _operations.ExecuteAsync(
            target,
            new KubePatchOperation(identity, payloadJson, options ?? new KubePatchOptions()),
            executionContext,
            cancellationToken).ConfigureAwait(false);
        return ResourceValidation.RequireResource(result, "Patch", identity, target);
    }

    public async ValueTask<KubeExecutionResult> DeleteAsync(
        KubeTarget target,
        ResourceIdentity identity,
        KubeDeleteOptions? options = null,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(identity);
        ResourceValidation.ValidateConcurrency(options?.Concurrency, identity, target);
        KubeOperationResult result = await _operations.ExecuteAsync(
            target,
            new KubeDeleteOperation(identity, options ?? new KubeDeleteOptions()),
            executionContext,
            cancellationToken).ConfigureAwait(false);
        return new KubeExecutionResult(result.Warnings, result.Diagnostics);
    }
}

/// <summary>
/// Narrow CRUD/resource facade. Mutation execution is delegated to the rich client and only Value is
/// returned; query convenience methods remain light-weight and preserve historical behavior.
/// </summary>
public sealed class KubeResourceClient : IKubeResourceClient
{
    private readonly IKubeOperationClient _operations;
    private readonly IKubeResourceExecutionClient _execution;

    public KubeResourceClient(IKubeOperationClient operations)
        : this(operations, new KubeResourceExecutionClient(operations)) { }

    public KubeResourceClient(IKubeOperationClient operations, IKubeResourceExecutionClient execution)
    {
        _operations = operations ?? throw new ArgumentNullException(nameof(operations));
        _execution = execution ?? throw new ArgumentNullException(nameof(execution));
    }

    public KubeResourceClient(IKubeBackend backend) : this(new KubeOperationClient(backend)) { }
    public KubeResourceClient(IEnumerable<IKubeBackend> backends) : this(new KubeOperationClient(backends)) { }
    public KubeResourceClient(IKubeBackendSelector selector) : this(new KubeOperationClient(selector)) { }

    public IReadOnlyList<KubeResource> Get(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) =>
        GetAsync(target, query, executionContext).GetAwaiter().GetResult();

    public bool Exists(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) =>
        ExistsAsync(target, query, executionContext).GetAwaiter().GetResult();

    public KubeResource? TryGet(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) =>
        TryGetAsync(target, query, executionContext).GetAwaiter().GetResult();

    public IReadOnlyList<string> ListNames(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) =>
        ListNamesAsync(target, query, executionContext).GetAwaiter().GetResult();

    public KubeResource Create(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null) =>
        CreateAsync(target, identity, payloadJson, options, executionContext).GetAwaiter().GetResult();

    public KubeResource Replace(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null) =>
        ReplaceAsync(target, identity, payloadJson, options, executionContext).GetAwaiter().GetResult();

    public KubeResource Apply(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null) =>
        ApplyAsync(target, identity, payloadJson, options, executionContext).GetAwaiter().GetResult();

    public KubeResource Patch(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null) =>
        PatchAsync(target, identity, payloadJson, options, executionContext).GetAwaiter().GetResult();

    public void Delete(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null) =>
        DeleteAsync(target, identity, options, executionContext).GetAwaiter().GetResult();

    public async ValueTask<IReadOnlyList<KubeResource>> GetAsync(
        KubeTarget target,
        ResourceQuery query,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default) =>
        (await _execution.GetAsync(target, query, executionContext, cancellationToken).ConfigureAwait(false)).Value;

    public async ValueTask<bool> ExistsAsync(
        KubeTarget target,
        ResourceQuery query,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateNamedQuery(target, query, nameof(query), "Exists");
        try
        {
            return (await _operations.ExecuteAsync(target, new KubeGetOperation(query.ToIdentity(target)), executionContext, cancellationToken).ConfigureAwait(false)).Resource is not null;
        }
        catch (KubeException ex) when (ex.Kind == KubeErrorKind.NotFound) { return false; }
    }

    public async ValueTask<KubeResource?> TryGetAsync(
        KubeTarget target,
        ResourceQuery query,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateNamedQuery(target, query, nameof(query), "TryGet");
        try
        {
            return (await _operations.ExecuteAsync(target, new KubeGetOperation(query.ToIdentity(target)), executionContext, cancellationToken).ConfigureAwait(false)).Resource;
        }
        catch (KubeException ex) when (ex.Kind == KubeErrorKind.NotFound) { return null; }
    }

    public async ValueTask<IReadOnlyList<string>> ListNamesAsync(
        KubeTarget target,
        ResourceQuery query,
        KubeExecutionContext? executionContext = null,
        CancellationToken cancellationToken = default)
    {
        ResourceValidation.ValidateQuery(target, query);
        if (!string.IsNullOrWhiteSpace(query.Name))
            throw new ArgumentException("ListNames requires a collection query without a resource name.", nameof(query));
        if (query.NamespaceScope.Kind == KubeNamespaceScopeKind.All)
            throw new ArgumentException("ListNames cannot represent all-namespaces results without losing namespace identity. Use Get and inspect each resource identity.", nameof(query));
        return (await GetAsync(target, query, executionContext, cancellationToken).ConfigureAwait(false)).Select(x => x.Identity.Name).ToArray();
    }

    public async ValueTask<KubeResource> CreateAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) =>
        (await _execution.CreateAsync(target, identity, payloadJson, options, executionContext, cancellationToken).ConfigureAwait(false)).Value;

    public async ValueTask<KubeResource> ReplaceAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) =>
        (await _execution.ReplaceAsync(target, identity, payloadJson, options, executionContext, cancellationToken).ConfigureAwait(false)).Value;

    public async ValueTask<KubeResource> ApplyAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) =>
        (await _execution.ApplyAsync(target, identity, payloadJson, options, executionContext, cancellationToken).ConfigureAwait(false)).Value;

    public async ValueTask<KubeResource> PatchAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) =>
        (await _execution.PatchAsync(target, identity, payloadJson, options, executionContext, cancellationToken).ConfigureAwait(false)).Value;

    public async ValueTask DeleteAsync(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) =>
        _ = await _execution.DeleteAsync(target, identity, options, executionContext, cancellationToken).ConfigureAwait(false);
}

internal static class ResourceValidation
{
    internal static void ValidateQuery(KubeTarget target, ResourceQuery query)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(query);
        if (!string.IsNullOrWhiteSpace(query.Name) &&
            (!string.IsNullOrWhiteSpace(query.LabelSelector) || !string.IsNullOrWhiteSpace(query.FieldSelector)))
            throw new ArgumentException("A named resource query cannot also use label or field selectors because a Kubernetes GET-by-name does not evaluate selectors.", nameof(query));
    }

    internal static void ValidateNamedQuery(KubeTarget target, ResourceQuery query, string parameterName, string operationName)
    {
        ValidateQuery(target, query);
        if (string.IsNullOrWhiteSpace(query.Name))
            throw new ArgumentException($"{operationName} requires a named resource query.", parameterName);
    }

    internal static void ValidateMutation(KubeTarget target, ResourceIdentity identity, string payloadJson)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(payloadJson);
    }

    internal static void ValidateConcurrency(KubeConcurrencyOptions? concurrency, ResourceIdentity identity, KubeTarget target)
    {
        if (concurrency is null || concurrency.Mode != KubeConcurrencyMode.RequireUnchanged) return;
        if (string.IsNullOrWhiteSpace(concurrency.ExpectedResourceVersion))
            throw new KubeException(
                KubeErrorKind.InvalidResource,
                "RequireUnchanged needs ExpectedResourceVersion.",
                resource: identity,
                target: target,
                code: "concurrency.resource-version-required");
    }

    internal static KubeExecutionResult<KubeResource> RequireResource(KubeOperationResult result, string operationName, ResourceIdentity identity, KubeTarget target)
    {
        KubeResource resource = result.Resource ?? throw new KubeException(
            KubeErrorKind.Transport,
            $"{operationName} backend returned no Kubernetes resource.",
            resource: identity,
            target: target);
        return new KubeExecutionResult<KubeResource>(resource, result.Warnings, result.Diagnostics);
    }
}
