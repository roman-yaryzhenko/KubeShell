package kube

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

type resolvedResource struct {
	gvr        schema.GroupVersionResource
	gvk        schema.GroupVersionKind
	namespaced bool
	descriptor protocol.ResourceDescriptor
}

func discoverPreferred(ctx context.Context, s *session, req protocol.DiscoverRequest) (protocol.DiscoverResponse, error) {
	bundle, err := s.bundle(req.Execution, req.Refresh)
	if err != nil {
		return protocol.DiscoverResponse{}, err
	}
	lists, err := bundle.client.ServerPreferredResourcesWithContext(ctx)
	if err != nil && len(lists) == 0 {
		return protocol.DiscoverResponse{}, err
	}
	resources := make([]protocol.ResourceDescriptor, 0)
	for _, list := range lists {
		if list == nil {
			continue
		}
		resources = append(resources, descriptorsFromAPIResourceList(list.GroupVersion, list.APIResources)...)
	}
	sortDescriptors(resources)
	// Discovery can return a partial result together with an aggregated error. Keep the useful
	// descriptors and let callers refresh/resolve a concrete resource if a group was unavailable.
	return protocol.DiscoverResponse{Resources: resources}, nil
}

func discoverAPIVersion(ctx context.Context, s *session, req protocol.DiscoverRequest) (protocol.DiscoverResponse, error) {
	bundle, err := s.bundle(req.Execution, req.Refresh)
	if err != nil {
		return protocol.DiscoverResponse{}, err
	}
	list, err := bundle.client.ServerResourcesForGroupVersionWithContext(ctx, req.APIVersion)
	if err != nil {
		return protocol.DiscoverResponse{}, err
	}
	return protocol.DiscoverResponse{Resources: descriptorsFromAPIResourceList(list.GroupVersion, list.APIResources)}, nil
}

func resolveResource(ctx context.Context, s *session, req protocol.DiscoverRequest) (protocol.DiscoverResponse, error) {
	if req.Resource == nil {
		return protocol.DiscoverResponse{}, fmt.Errorf("resource is required")
	}
	resolved, err := resolve(ctx, s, req.Execution, *req.Resource, req.Refresh)
	if err != nil {
		return protocol.DiscoverResponse{}, err
	}
	return protocol.DiscoverResponse{Resources: []protocol.ResourceDescriptor{resolved.descriptor}}, nil
}

func resolve(ctx context.Context, s *session, exec protocol.ExecutionContext, input protocol.GVR, refresh bool) (resolvedResource, error) {
	resolved, err := resolveOnce(ctx, s, exec, input, refresh)
	if err != nil && !refresh && meta.IsNoMatchError(err) {
		return resolveOnce(ctx, s, exec, input, true)
	}
	return resolved, err
}

func resolveOnce(ctx context.Context, s *session, exec protocol.ExecutionContext, input protocol.GVR, refresh bool) (resolvedResource, error) {
	bundle, err := s.bundle(exec, refresh)
	if err != nil {
		return resolvedResource{}, err
	}

	var resources []protocol.ResourceDescriptor
	var preferred []protocol.ResourceDescriptor
	var partialErr error
	if input.Version != "" {
		apiVersion := input.Version
		if input.Group != "" {
			apiVersion = input.Group + "/" + input.Version
		}
		list, discoverErr := bundle.client.ServerResourcesForGroupVersionWithContext(ctx, apiVersion)
		if discoverErr != nil {
			return resolvedResource{}, discoverErr
		}
		resources = descriptorsFromAPIResourceList(list.GroupVersion, list.APIResources)
		preferred = resources
	} else {
		_, lists, discoverErr := bundle.client.ServerGroupsAndResourcesWithContext(ctx)
		partialErr = discoverErr
		if discoverErr != nil && len(lists) == 0 {
			return resolvedResource{}, discoverErr
		}
		for _, list := range lists {
			if list != nil {
				resources = append(resources, descriptorsFromAPIResourceList(list.GroupVersion, list.APIResources)...)
			}
		}
		preferredLists, preferredErr := bundle.client.ServerPreferredResourcesWithContext(ctx)
		if preferredErr == nil || len(preferredLists) > 0 {
			for _, list := range preferredLists {
				if list != nil {
					preferred = append(preferred, descriptorsFromAPIResourceList(list.GroupVersion, list.APIResources)...)
				}
			}
		}
	}

	descriptor, selectErr := selectResourceDescriptor(input, resources, preferred)
	if selectErr != nil {
		if meta.IsNoMatchError(selectErr) && partialErr != nil {
			return resolvedResource{}, partialErr
		}
		return resolvedResource{}, selectErr
	}
	gvr := schema.GroupVersionResource{Group: descriptor.GVR.Group, Version: descriptor.GVR.Version, Resource: descriptor.GVR.Resource}
	gvk := schema.GroupVersionKind{Group: descriptor.GVR.Group, Version: descriptor.GVR.Version, Kind: descriptor.Kind}
	return resolvedResource{gvr: gvr, gvk: gvk, namespaced: descriptor.Namespaced, descriptor: descriptor}, nil
}

// selectResourceDescriptor implements KubeShell's backend-neutral token semantics. Versions of
// one GroupResource are one logical candidate; different GroupResources remain ambiguous even
// when client-go shortcut expansion would otherwise pick a priority winner. [D2/D9]
func selectResourceDescriptor(input protocol.GVR, resources, preferred []protocol.ResourceDescriptor) (protocol.ResourceDescriptor, error) {
	partial := schema.GroupVersionResource{Group: input.Group, Version: input.Version, Resource: input.Resource}
	if strings.TrimSpace(input.Resource) == "" {
		return protocol.ResourceDescriptor{}, &meta.NoResourceMatchError{PartialResource: partial}
	}
	hasVersion := input.Version != ""
	constrainGroup := hasVersion || input.Group != ""

	matches := make([]protocol.ResourceDescriptor, 0)
	for _, descriptor := range resources {
		if constrainGroup && !strings.EqualFold(descriptor.GVR.Group, input.Group) {
			continue
		}
		if hasVersion && !strings.EqualFold(descriptor.GVR.Version, input.Version) {
			continue
		}
		if descriptorMatchesToken(descriptor, input.Resource) {
			matches = append(matches, descriptor)
		}
	}
	if len(matches) == 0 {
		return protocol.ResourceDescriptor{}, &meta.NoResourceMatchError{PartialResource: partial}
	}

	preferredByGR := make(map[string]protocol.ResourceDescriptor)
	for _, descriptor := range preferred {
		key := descriptorGroupResourceKey(descriptor)
		if _, exists := preferredByGR[key]; !exists {
			preferredByGR[key] = descriptor
		}
	}
	logical := make(map[string]protocol.ResourceDescriptor)
	for _, descriptor := range matches {
		key := descriptorGroupResourceKey(descriptor)
		if _, exists := logical[key]; exists {
			continue
		}
		if selected, ok := preferredByGR[key]; ok {
			logical[key] = selected
		} else {
			logical[key] = descriptor
		}
	}
	if len(logical) == 1 {
		for _, descriptor := range logical {
			return descriptor, nil
		}
	}

	matching := make([]schema.GroupVersionResource, 0, len(logical))
	for _, descriptor := range logical {
		matching = append(matching, schema.GroupVersionResource{
			Group: descriptor.GVR.Group, Version: descriptor.GVR.Version, Resource: descriptor.GVR.Resource,
		})
	}
	sort.Slice(matching, func(i, j int) bool { return matching[i].String() < matching[j].String() })
	return protocol.ResourceDescriptor{}, &meta.AmbiguousResourceError{PartialResource: partial, MatchingResources: matching}
}

func descriptorMatchesToken(descriptor protocol.ResourceDescriptor, token string) bool {
	canonical := descriptor.GVR.Resource
	if descriptor.GVR.Group != "" {
		canonical += "." + descriptor.GVR.Group
	}
	if strings.EqualFold(canonical, token) || strings.EqualFold(descriptor.GVR.Resource, token) || strings.EqualFold(descriptor.SingularName, token) || strings.EqualFold(descriptor.Kind, token) {
		return true
	}
	for _, shortName := range descriptor.ShortNames {
		if strings.EqualFold(shortName, token) {
			return true
		}
	}
	return false
}

func descriptorGroupResourceKey(descriptor protocol.ResourceDescriptor) string {
	return strings.ToLower(descriptor.GVR.Group) + "\x1f" + strings.ToLower(descriptor.GVR.Resource)
}

func descriptorsFromAPIResourceList(groupVersion string, resources []metav1.APIResource) []protocol.ResourceDescriptor {
	gv, err := schema.ParseGroupVersion(groupVersion)
	if err != nil {
		return nil
	}
	parents := make(map[string]*protocol.ResourceDescriptor)
	subresources := make([]metav1.APIResource, 0)
	for _, apiResource := range resources {
		if strings.Contains(apiResource.Name, "/") {
			subresources = append(subresources, apiResource)
			continue
		}
		d := protocol.ResourceDescriptor{
			GVR:          protocol.GVR{Group: gv.Group, Version: gv.Version, Resource: apiResource.Name},
			Kind:         apiResource.Kind,
			Namespaced:   apiResource.Namespaced,
			Verbs:        append([]string(nil), apiResource.Verbs...),
			SingularName: apiResource.SingularName,
			ShortNames:   append([]string(nil), apiResource.ShortNames...),
			Categories:   append([]string(nil), apiResource.Categories...),
		}
		parents[apiResource.Name] = &d
	}
	for _, apiResource := range subresources {
		parts := strings.SplitN(apiResource.Name, "/", 2)
		parent := parents[parts[0]]
		if parent == nil {
			continue
		}
		group, version := gv.Group, gv.Version
		if apiResource.Group != "" {
			group = apiResource.Group
		}
		if apiResource.Version != "" {
			version = apiResource.Version
		}
		parent.Subresources = append(parent.Subresources, protocol.SubresourceDescriptor{
			Name: parts[1], Group: group, Version: version, Kind: apiResource.Kind,
			Namespaced: apiResource.Namespaced, Verbs: append([]string(nil), apiResource.Verbs...),
		})
	}
	result := make([]protocol.ResourceDescriptor, 0, len(parents))
	for _, item := range parents {
		sort.Slice(item.Subresources, func(i, j int) bool { return item.Subresources[i].Name < item.Subresources[j].Name })
		result = append(result, *item)
	}
	sortDescriptors(result)
	return result
}

func scopeNamespace(scope protocol.NamespaceScope, namespaced bool, defaultNamespace string, allowAll bool) (string, error) {
	switch strings.ToLower(scope.Kind) {
	case "explicit":
		if !namespaced {
			return "", fmt.Errorf("explicit namespace is invalid for a cluster-scoped resource")
		}
		if scope.Name == "" {
			return "", fmt.Errorf("explicit namespace requires a name")
		}
		return scope.Name, nil
	case "all":
		if !allowAll {
			return "", fmt.Errorf("all-namespaces scope is not valid for this operation")
		}
		if !namespaced {
			return "", nil
		}
		return "", nil
	case "cluster":
		if namespaced {
			return "", fmt.Errorf("cluster scope is invalid for a namespaced resource")
		}
		return "", nil
	case "default", "":
		if namespaced {
			return defaultNamespace, nil
		}
		return "", nil
	default:
		return "", fmt.Errorf("unknown namespace scope %q", scope.Kind)
	}
}

// Keep deterministic descriptor output: it makes protocol snapshots and diagnostics stable.
func sortDescriptors(items []protocol.ResourceDescriptor) {
	sort.Slice(items, func(i, j int) bool {
		a, b := items[i].GVR, items[j].GVR
		if a.Group != b.Group {
			return a.Group < b.Group
		}
		if a.Version != b.Version {
			return a.Version < b.Version
		}
		return a.Resource < b.Resource
	})
}
