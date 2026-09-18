using System;
using System.Collections.Generic;
using System.Linq;

namespace KubeShell.Runtime;

/// <summary>
/// Backend-neutral resource-token resolution over discovery descriptors. Versions of one
/// GroupResource are one logical candidate; a preferred descriptor is selected when available.
/// Different GroupResources that match the same plural/singular/kind/short-name remain ambiguous.
/// </summary>
public static class KubeDiscoveryResolution
{
    public static KubeResourceDescriptor? Resolve(
        GroupVersionResource request,
        IEnumerable<KubeResourceDescriptor> resources,
        IEnumerable<KubeResourceDescriptor>? preferredResources = null,
        KubeTarget? target = null,
        string ambiguityCode = "runtime.discovery.ambiguous-resource")
    {
        if (string.IsNullOrWhiteSpace(request.Resource)) return null;
        ArgumentNullException.ThrowIfNull(resources);

        KubeResourceDescriptor[] all = resources.ToArray();
        KubeResourceDescriptor[] preferred = (preferredResources ?? Array.Empty<KubeResourceDescriptor>()).ToArray();
        bool hasVersion = !string.IsNullOrWhiteSpace(request.Version);
        // With an explicit version, an empty group means the core API group. With no version/group,
        // the request is an alias lookup and the token may match any API group.
        bool constrainGroup = hasVersion || !string.IsNullOrWhiteSpace(request.Group);

        KubeResourceDescriptor[] tokenMatches = all.Where(descriptor =>
            (!constrainGroup || string.Equals(descriptor.Gvr.Group, request.Group, StringComparison.OrdinalIgnoreCase)) &&
            (!hasVersion || string.Equals(descriptor.Gvr.Version, request.Version, StringComparison.OrdinalIgnoreCase)) &&
            MatchesToken(descriptor, request.Resource)).ToArray();

        if (tokenMatches.Length == 0) return null;

        Dictionary<string, KubeResourceDescriptor> preferredByGroupResource = preferred
            .GroupBy(GroupResourceKey, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.OrdinalIgnoreCase);

        KubeResourceDescriptor[] logicalCandidates = tokenMatches
            .GroupBy(GroupResourceKey, StringComparer.OrdinalIgnoreCase)
            .Select(group => preferredByGroupResource.TryGetValue(group.Key, out KubeResourceDescriptor? preferredDescriptor)
                ? preferredDescriptor
                : group.First())
            .OrderBy(descriptor => GroupResource.From(descriptor.Gvr).ToString(), StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (logicalCandidates.Length == 1) return logicalCandidates[0];

        string candidates = string.Join(", ", logicalCandidates
            .Select(descriptor => GroupResource.From(descriptor.Gvr).ToString())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase));
        throw new KubeException(
            KubeErrorKind.InvalidResource,
            $"Kubernetes resource token '{request.Resource}' is ambiguous. Candidates: {candidates}.",
            target: target,
            code: ambiguityCode);
    }

    private static bool MatchesToken(KubeResourceDescriptor descriptor, string token) =>
        string.Equals(GroupResource.From(descriptor.Gvr).ToString(), token, StringComparison.OrdinalIgnoreCase) ||
        descriptor.MatchesResourceToken(token);

    private static string GroupResourceKey(KubeResourceDescriptor descriptor) =>
        $"{descriptor.Gvr.Group}\u001f{descriptor.Gvr.Resource}";
}
