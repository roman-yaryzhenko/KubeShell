using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Nodes;
using k8s.Autorest;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubernetesClient;

/// <summary>
/// Translates SDK/HTTP response details into backend-neutral Runtime values. Transport-specific status
/// codes stay here and are exposed only as diagnostics, never as fields on KubeException/KubeError.
/// </summary>
internal static class KubernetesResponseMapper
{
    public static KubeOperationResult Result(HttpOperationResponse<JsonElement> response, GroupVersionResource gvr, bool tolerateStatusObject = false)
    {
        List<KubeWarning> warnings = ReadWarnings(response.Response);
        JsonElement body = response.Body;
        if (body.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
            return new KubeOperationResult(warnings: warnings);

        JsonNode? node = JsonNode.Parse(body.GetRawText());
        if (node is not JsonObject obj)
            return new KubeOperationResult(warnings: warnings);
        if (obj["items"] is JsonArray items)
            return new KubeOperationResult(items.OfType<JsonObject>().Select(x => KubeResource.FromDocument(gvr, x)), warnings);
        if (tolerateStatusObject && string.Equals(obj["kind"]?.GetValue<string>(), "Status", StringComparison.OrdinalIgnoreCase))
            return new KubeOperationResult(warnings: warnings);
        return new KubeOperationResult(new[] { KubeResource.FromDocument(gvr, obj) }, warnings);
    }

    public static KubeException FromHttpException(HttpOperationException exception, KubeTarget target, ResourceIdentity? resource = null)
    {
        int? status = exception.Response is null ? null : (int)exception.Response.StatusCode;
        KubeErrorKind kind = status switch
        {
            400 => KubeErrorKind.InvalidResource,
            401 => KubeErrorKind.Authentication,
            403 => KubeErrorKind.Authorization,
            404 => KubeErrorKind.NotFound,
            405 => KubeErrorKind.Unsupported,
            409 => KubeErrorKind.Conflict,
            422 => KubeErrorKind.InvalidResource,
            _ => KubeErrorKind.Transport
        };
        IReadOnlyList<KubeWarning> warnings = exception.Response is null
            ? Array.Empty<KubeWarning>()
            : ReadWarnings(exception.Response.Headers);
        IReadOnlyList<KubeDiagnostic> diagnostics = status.HasValue
            ? new[] { new KubeDiagnostic("backend.http-status", $"Kubernetes API HTTP status: {status.Value}.", KubeDiagnosticLevel.Trace) }
            : Array.Empty<KubeDiagnostic>();
        return new KubeException(kind, exception.Message, exception, resource, target, "managed.http", warnings, diagnostics);
    }

    private static List<KubeWarning> ReadWarnings(HttpResponseMessage response)
    {
        if (response.Headers.TryGetValues("Warning", out IEnumerable<string>? values))
            return values.Select(x => new KubeWarning(x, "http.warning", "kube-apiserver")).ToList();
        return new List<KubeWarning>();
    }

    private static List<KubeWarning> ReadWarnings(IDictionary<string, IEnumerable<string>> headers)
    {
        if (headers.TryGetValue("Warning", out IEnumerable<string>? values))
            return values.Select(x => new KubeWarning(x, "http.warning", "kube-apiserver")).ToList();
        return new List<KubeWarning>();
    }
}
