using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubectlProcess;

/// <summary>
/// Compatibility backend for the existing external kubectl process. It lives outside Runtime and
/// is intentionally distinct from the long-lived kubectl-host/client-go backend.
/// </summary>
public sealed class KubectlProcessBackend : IKubeBackend
{
    private readonly KubectlProcessTransport _transport;

    public KubectlProcessBackend(string executable = "kubectl")
        : this(new KubectlProcessTransport(executable)) { }

    internal KubectlProcessBackend(KubectlProcessTransport transport)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
    }

    public string Id => "kubectl-process";

    public ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(executionContext);

        if (!KubectlProcessTransport.CanRepresentKubeConfigPaths(target))
            return ValueTask.FromResult(KubeOperationSupport.Unsupported(
                "kubectl-process.kubeconfig-unrepresentable",
                "The external kubectl compatibility backend cannot safely encode one or more kubeconfig paths in KUBECONFIG."));

        if (executionContext.FieldValidation != KubeFieldValidationMode.Default)
            return ValueTask.FromResult(KubeOperationSupport.Unsupported(
                "kubectl-process.field-validation",
                "The external kubectl compatibility backend does not preserve Runtime field-validation semantics."));
        if (!string.IsNullOrWhiteSpace(executionContext.UserAgent))
            return ValueTask.FromResult(KubeOperationSupport.Unsupported(
                "kubectl-process.user-agent",
                "The external kubectl compatibility backend cannot guarantee the requested User-Agent."));
        if (executionContext.Impersonation is { EffectiveExtra.Count: > 0 })
            return ValueTask.FromResult(KubeOperationSupport.Unsupported(
                "kubectl-process.impersonation-extra",
                "The external kubectl compatibility backend does not map impersonation extra fields."));

        if (operation is not (KubeGetOperation or KubeListOperation or KubeCreateOperation or KubeReplaceOperation or KubeDeleteOperation or KubePatchOperation or KubeApplyOperation))
            return ValueTask.FromResult(KubeOperationSupport.Unsupported("kubectl-process.operation", $"The external kubectl fallback does not implement semantic operation {operation.GetType().Name}."));

        if (HasUnsupportedConcurrency(operation))
            return ValueTask.FromResult(KubeOperationSupport.Unsupported("kubectl-process.concurrency", "The external kubectl compatibility backend cannot promise the requested optimistic-concurrency policy for this operation."));

        if (HasSubresource(operation))
            return ValueTask.FromResult(KubeOperationSupport.Unknown("kubectl-process.subresource", "Subresource support depends on the concrete kubectl command and server discovery."));

        return ValueTask.FromResult(KubeOperationSupport.Supported("kubectl-process.compatibility", "Operation is mapped to the external kubectl CLI."));
    }

    public async ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default)
    {
        KubeOperationSupport support = await EvaluateAsync(operation, target, executionContext, cancellationToken).ConfigureAwait(false);
        if (support.State != KubeSupportState.Supported)
        {
            KubeErrorKind kind = support.ToFailureKind();
            throw new KubeException(
                kind,
                support.Reason ?? "kubectl process backend cannot prove support for this operation.",
                target: target,
                code: support.ReasonCode);
        }

        List<string> args = new();
        string? input = null;
        GroupVersionResource? expectedGvr = null;
        ResourceIdentity? identity = null;
        bool expectJson = true;

        switch (operation)
        {
            case KubeGetOperation get:
                identity = get.Identity;
                expectedGvr = identity.Gvr;
                args.AddRange(new[] { "get", ResourceToken(identity.Gvr), identity.Name });
                AddIdentityScope(args, identity, target);
                args.AddRange(new[] { "-o", "json" });
                break;

            case KubeListOperation list:
                expectedGvr = list.Query.Gvr;
                args.AddRange(new[] { "get", ResourceToken(list.Query.Gvr) });
                AddQueryScope(args, list.Query, target);
                if (!string.IsNullOrWhiteSpace(list.Query.LabelSelector)) { args.Add("--selector"); args.Add(list.Query.LabelSelector); }
                if (!string.IsNullOrWhiteSpace(list.Query.FieldSelector)) { args.Add("--field-selector"); args.Add(list.Query.FieldSelector); }
                args.AddRange(new[] { "-o", "json" });
                break;

            case KubeCreateOperation create:
                identity = create.Identity; expectedGvr = identity.Gvr;
                args.AddRange(new[] { "create", "-f", "-", "-o", "json" });
                AddIdentityScope(args, identity, target);
                AddPreview(args, create.Options.Preview);
                if (!string.IsNullOrWhiteSpace(create.Options.FieldManager)) args.Add("--field-manager=" + create.Options.FieldManager);
                input = create.PayloadJson;
                break;

            case KubeReplaceOperation replace:
                identity = replace.Identity; expectedGvr = identity.Gvr;
                args.AddRange(new[] { "replace", "-f", "-", "-o", "json" });
                AddIdentityScope(args, identity, target);
                AddPreview(args, replace.Options.Preview);
                if (!string.IsNullOrWhiteSpace(replace.Options.FieldManager)) args.Add("--field-manager=" + replace.Options.FieldManager);
                input = replace.PayloadJson;
                break;

            case KubeApplyOperation apply:
                identity = apply.Identity; expectedGvr = identity.Gvr;
                args.AddRange(new[] { "apply", "-f", "-", "-o", "json" });
                AddIdentityScope(args, identity, target);
                if (apply.Options.Strategy == KubeApplyStrategy.ServerSide) args.Add("--server-side");
                if (!string.IsNullOrWhiteSpace(apply.Options.FieldManager)) args.Add("--field-manager=" + apply.Options.FieldManager);
                if (apply.Options.ForceConflicts) args.Add("--force-conflicts");
                AddPreview(args, apply.Options.Preview);
                input = apply.PayloadJson;
                break;

            case KubePatchOperation patch:
                identity = patch.Identity; expectedGvr = identity.Gvr;
                args.AddRange(new[] { "patch", ResourceToken(identity.Gvr), identity.Name, "--type=" + PatchToken(patch.Options.Type), "-p", patch.PayloadJson, "-o", "json" });
                AddIdentityScope(args, identity, target);
                AddPreview(args, patch.Options.Preview);
                if (!string.IsNullOrWhiteSpace(patch.Options.FieldManager)) args.Add("--field-manager=" + patch.Options.FieldManager);
                break;

            case KubeDeleteOperation delete:
                identity = delete.Identity; expectedGvr = identity.Gvr;
                args.AddRange(new[] { "delete", ResourceToken(identity.Gvr), identity.Name });
                AddIdentityScope(args, identity, target);
                AddPreview(args, delete.Options.Preview);
                if (delete.Options.Force)
                {
                    args.Add("--force");
                    args.Add("--grace-period=0");
                }
                else if (delete.Options.GracePeriodSeconds.HasValue)
                {
                    args.Add("--grace-period=" + delete.Options.GracePeriodSeconds.Value);
                }
                // kubectl delete does not reliably return the deleted resource as JSON across versions.
                expectJson = false;
                break;

            default:
                throw new KubeException(KubeErrorKind.Unsupported, $"kubectl process backend does not implement {operation.GetType().Name}.", code: "kubectl-process.operation");
        }

        KubectlProcessResult result = await _transport.ExecuteAsync(
            target,
            AddExecutionArguments(args, executionContext),
            input,
            includeContext: true,
            includeNamespace: false,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!result.IsSuccess) ThrowProcessError(result, identity, target);

        IReadOnlyList<KubeResource> resources = expectJson && !string.IsNullOrWhiteSpace(result.StdOut)
            ? ParseResources(expectedGvr ?? default, result.StdOut)
            : Array.Empty<KubeResource>();
        return new KubeOperationResult(resources, ParseWarnings(result.StdErr));
    }

    private static IEnumerable<string> AddExecutionArguments(IEnumerable<string> arguments, KubeExecutionContext context)
    {
        List<string> prefix = new();
        if (context.Impersonation is { } imp)
        {
            if (!string.IsNullOrWhiteSpace(imp.User)) prefix.Add("--as=" + imp.User);
            if (!string.IsNullOrWhiteSpace(imp.Uid)) prefix.Add("--as-uid=" + imp.Uid);
            foreach (string group in imp.EffectiveGroups) prefix.Add("--as-group=" + group);
        }
        if (context.Timeout is { } timeout && timeout > TimeSpan.Zero)
            prefix.Add("--request-timeout=" + Math.Ceiling(timeout.TotalSeconds) + "s");
        prefix.AddRange(arguments);
        return prefix;
    }

    private static void AddIdentityScope(List<string> args, ResourceIdentity identity, KubeTarget target) => AddScope(args, identity.NamespaceScope, target);
    private static void AddQueryScope(List<string> args, ResourceQuery query, KubeTarget target) => AddScope(args, query.NamespaceScope, target);

    private static void AddScope(List<string> args, KubeNamespaceScope scope, KubeTarget target)
    {
        switch (scope.Kind)
        {
            case KubeNamespaceScopeKind.Explicit:
                args.Add("--namespace"); args.Add(scope.Name!); break;
            case KubeNamespaceScopeKind.All:
                args.Add("--all-namespaces"); break;
            case KubeNamespaceScopeKind.Default when !string.IsNullOrWhiteSpace(target.DefaultNamespace):
                args.Add("--namespace"); args.Add(target.DefaultNamespace); break;
        }
    }

    private static void AddPreview(List<string> args, KubePreviewMode preview)
    {
        if (preview != KubePreviewMode.None) args.Add("--dry-run=" + preview.ToString().ToLowerInvariant());
    }

    private static string PatchToken(KubePatchType type) => type switch
    {
        KubePatchType.Json => "json",
        KubePatchType.Strategic => "strategic",
        _ => "merge"
    };

    private static string ResourceToken(GroupVersionResource gvr) => string.IsNullOrWhiteSpace(gvr.Group) ? gvr.Resource : $"{gvr.Resource}.{gvr.Group}";

    private static bool HasSubresource(KubeOperation operation) => operation switch
    {
        KubeGetOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeListOperation x => !string.IsNullOrWhiteSpace(x.Query.Subresource),
        KubeCreateOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeReplaceOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeApplyOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubePatchOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        KubeDeleteOperation x => !string.IsNullOrWhiteSpace(x.Identity.Subresource),
        _ => false
    };

    private static bool HasUnsupportedConcurrency(KubeOperation operation) => operation switch
    {
        KubeReplaceOperation x => x.Options.Concurrency.Mode != KubeConcurrencyMode.Default,
        KubePatchOperation x => x.Options.Concurrency.Mode != KubeConcurrencyMode.Default,
        KubeDeleteOperation x => x.Options.Concurrency.Mode != KubeConcurrencyMode.Default,
        _ => false
    };

    private static IReadOnlyList<KubeResource> ParseResources(GroupVersionResource gvr, string json)
    {
        JsonNode? root = JsonNode.Parse(json);
        if (root is not JsonObject obj) throw new KubeException(KubeErrorKind.Serialization, "kubectl returned non-object JSON.");
        if (obj["items"] is JsonArray items)
            return items.OfType<JsonObject>().Select(item => KubeResource.FromDocument(gvr, item)).ToArray();
        return new[] { KubeResource.FromDocument(gvr, obj) };
    }

    private static void ThrowProcessError(KubectlProcessResult result, ResourceIdentity? identity, KubeTarget target)
    {
        string stderr = result.StdErr ?? string.Empty;
        KubeErrorKind kind = stderr.Contains("(NotFound)", StringComparison.OrdinalIgnoreCase) || stderr.Contains(" not found", StringComparison.OrdinalIgnoreCase)
            ? KubeErrorKind.NotFound
            : stderr.Contains("Forbidden", StringComparison.OrdinalIgnoreCase) ? KubeErrorKind.Authorization
            : stderr.Contains("Unauthorized", StringComparison.OrdinalIgnoreCase) ? KubeErrorKind.Authentication
            : stderr.Contains("(AlreadyExists)", StringComparison.OrdinalIgnoreCase) || stderr.Contains(" already exists", StringComparison.OrdinalIgnoreCase) || stderr.Contains("(Conflict)", StringComparison.OrdinalIgnoreCase)
                ? KubeErrorKind.Conflict
            : stderr.Contains("(Invalid)", StringComparison.OrdinalIgnoreCase) || stderr.Contains("(BadRequest)", StringComparison.OrdinalIgnoreCase)
                ? KubeErrorKind.InvalidResource
            : stderr.Contains("(MethodNotAllowed)", StringComparison.OrdinalIgnoreCase) || stderr.Contains("method not allowed", StringComparison.OrdinalIgnoreCase)
                ? KubeErrorKind.Unsupported
                : KubeErrorKind.Transport;
        string message = string.IsNullOrWhiteSpace(stderr) ? $"kubectl exited with code {result.ExitCode}." : stderr.Trim();
        throw new KubeException(
            kind,
            message,
            resource: identity,
            target: target,
            code: "kubectl-process.failed",
            warnings: ParseWarnings(stderr),
            diagnostics: new[]
            {
                new KubeDiagnostic("backend.exit-code", $"kubectl process exit code: {result.ExitCode}.", KubeDiagnosticLevel.Trace)
            });
    }

    private static IReadOnlyList<KubeWarning> ParseWarnings(string? stderr)
    {
        if (string.IsNullOrWhiteSpace(stderr)) return Array.Empty<KubeWarning>();
        return stderr
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .Where(line => line.StartsWith("Warning:", StringComparison.OrdinalIgnoreCase))
            .Select(line => new KubeWarning(line["Warning:".Length..].Trim(), "kubectl.warning", "kubectl"))
            .ToArray();
    }

}
