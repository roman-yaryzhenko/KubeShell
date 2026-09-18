using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace KubeShell.Runtime;

public static class KubeWireSerializer
{
    private static readonly HashSet<string> ServerOwnedMetadataFields = new(StringComparer.Ordinal)
    {
        "uid", "resourceVersion", "generation", "creationTimestamp", "managedFields", "selfLink"
    };

    public static string PrepareApplyJson(string json)
    {
        try
        {
            JsonNode? parsed = JsonNode.Parse(json);
            if (parsed is not JsonObject root)
                throw new KubeException(KubeErrorKind.Serialization, "Kubernetes apply payload root is not a JSON object.");

            root.Remove("status");
            if (root["metadata"] is JsonObject metadata)
                foreach (string field in ServerOwnedMetadataFields) metadata.Remove(field);
            return root.ToJsonString(KubeJson.Options);
        }
        catch (KubeException) { throw; }
        catch (JsonException exception)
        {
            throw new KubeException(KubeErrorKind.Serialization, "Kubernetes apply payload is not valid JSON: " + exception.Message, exception);
        }
    }

    internal static void ValidateJson(string payloadJson, ResourceIdentity? resource = null)
    {
        ArgumentNullException.ThrowIfNull(payloadJson);
        try
        {
            using JsonDocument _ = JsonDocument.Parse(payloadJson);
        }
        catch (JsonException exception)
        {
            throw new KubeException(KubeErrorKind.Serialization, "The Kubernetes payload must be valid JSON.", exception, resource: resource);
        }
    }

    public static void ValidateIdentity(string payloadJson, ResourceIdentity expected, KubeTarget? target = null)
    {
        ArgumentNullException.ThrowIfNull(expected);
        try
        {
            JsonNode? parsed = JsonNode.Parse(payloadJson);
            if (parsed is not JsonObject root)
                throw new KubeException(KubeErrorKind.InvalidResource, "Kubernetes resource payload root must be a JSON object.", resource: expected);

            string? name = root["metadata"]?["name"]?.GetValue<string>();
            if (!string.Equals(name, expected.Name, StringComparison.Ordinal))
                throw new KubeException(KubeErrorKind.InvalidResource, "Payload metadata.name must match the Kubernetes resource identity.", resource: expected);

            string? payloadNamespace = root["metadata"]?["namespace"]?.GetValue<string>();
            if (expected.NamespaceScope.Kind == KubeNamespaceScopeKind.Cluster && !string.IsNullOrWhiteSpace(payloadNamespace))
                throw new KubeException(KubeErrorKind.InvalidResource, "A cluster-scoped Kubernetes resource payload must not set metadata.namespace.", resource: expected);

            if (expected.NamespaceScope.Kind == KubeNamespaceScopeKind.Default &&
                target is not null &&
                string.IsNullOrWhiteSpace(target.DefaultNamespace) &&
                !string.IsNullOrWhiteSpace(payloadNamespace))
                throw new KubeException(
                    KubeErrorKind.InvalidResource,
                    "A payload namespace requires an explicit resource namespace when the Runtime target has no resolved default namespace.",
                    resource: expected,
                    target: target);

            string? expectedNamespace = expected.NamespaceScope.Kind switch
            {
                KubeNamespaceScopeKind.Explicit => expected.NamespaceScope.Name,
                KubeNamespaceScopeKind.Default when target is not null => target.DefaultNamespace,
                _ => null
            };
            if (!string.IsNullOrWhiteSpace(expectedNamespace) && !string.IsNullOrWhiteSpace(payloadNamespace) &&
                !string.Equals(payloadNamespace, expectedNamespace, StringComparison.Ordinal))
                throw new KubeException(KubeErrorKind.InvalidResource, "Payload metadata.namespace must match the effective Kubernetes resource namespace.", resource: expected, target: target);

            string? payloadKind = root["kind"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(payloadKind))
                throw new KubeException(KubeErrorKind.InvalidResource, "Kubernetes resource payload kind is required.", resource: expected);
            if (!string.IsNullOrWhiteSpace(expected.Kind) &&
                !string.Equals(payloadKind, expected.Kind, StringComparison.OrdinalIgnoreCase))
                throw new KubeException(KubeErrorKind.InvalidResource, "Payload kind must match the Kubernetes resource identity.", resource: expected);

            string? payloadApiVersion = root["apiVersion"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(payloadApiVersion))
                throw new KubeException(KubeErrorKind.InvalidResource, "Kubernetes resource payload apiVersion is required.", resource: expected);

            // Group identity is known even when the GVR is version-neutral. H7 requires a
            // mismatching payload group to fail before routing; only the version comparison
            // depends on discovery having resolved a concrete GVR.
            int groupSeparator = payloadApiVersion.IndexOf('/');
            string payloadGroup = groupSeparator < 0 ? string.Empty : payloadApiVersion[..groupSeparator];
            if (!string.Equals(payloadGroup, expected.Gvr.Group ?? string.Empty, StringComparison.Ordinal))
                throw new KubeException(KubeErrorKind.InvalidResource, "Payload apiVersion group must match the Kubernetes resource identity.", resource: expected);

            if (expected.Gvr.IsResolved &&
                !string.Equals(payloadApiVersion, expected.Gvr.ApiVersion, StringComparison.Ordinal))
                throw new KubeException(KubeErrorKind.InvalidResource, "Payload apiVersion must match the Kubernetes resource identity.", resource: expected);
        }
        catch (KubeException) { throw; }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException)
        {
            throw new KubeException(KubeErrorKind.Serialization, "The Kubernetes resource payload must be valid JSON.", exception, resource: expected);
        }
    }
}
