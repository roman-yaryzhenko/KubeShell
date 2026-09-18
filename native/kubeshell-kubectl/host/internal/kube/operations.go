package kube

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

type warningCollector struct {
	mu       sync.Mutex
	messages []string
}

func (w *warningCollector) HandleWarningHeader(code int, agent, message string) {
	if message == "" {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if agent != "" {
		w.messages = append(w.messages, fmt.Sprintf("%s: %s", agent, message))
	} else {
		w.messages = append(w.messages, message)
	}
}
func (w *warningCollector) snapshot() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]string(nil), w.messages...)
}

func operationConfig(ctx context.Context, s *session, exec protocol.ExecutionContext) (*rest.Config, *warningCollector) {
	cfg := s.configFor(exec)
	bindRequestContext(cfg, ctx)
	warnings := &warningCollector{}
	cfg.WarningHandler = warnings
	cfg.WarningHandlerWithContext = nil
	return cfg, warnings
}

func executeOperation(ctx context.Context, s *session, method protocol.Method, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	switch method {
	case protocol.MethodGet:
		return getResource(ctx, s, req)
	case protocol.MethodList:
		return listResources(ctx, s, req)
	case protocol.MethodCreate:
		return createResource(ctx, s, req)
	case protocol.MethodReplace:
		return replaceResource(ctx, s, req)
	case protocol.MethodDelete:
		return deleteResource(ctx, s, req)
	case protocol.MethodPatch:
		return patchResource(ctx, s, req)
	case protocol.MethodApply:
		return applyResource(ctx, s, req)
	default:
		return protocol.OperationResponse{}, unsupported("kubectl.operation", fmt.Sprintf("operation method %d is not implemented", method))
	}
}

func getResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("kubectl.resource-required", "resource identity is required")
	}
	target, iface, _, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.get.prepare")
	}
	obj, err := iface.Get(ctx, req.Resource.Name, metav1.GetOptions{}, subresourceArgs(req.Resource.Subresource)...)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.get")
	}
	return resultForObject(target, obj, warnings, "kubectl.get.serialize")
}

func listResources(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if req.Query == nil {
		return protocol.OperationResponse{}, invalid("kubectl.query-required", "resource query is required")
	}
	if req.Query.Subresource != "" {
		return protocol.OperationResponse{}, unsupported("kubectl.list-subresource", "generic subresource list is not defined by the dynamic client")
	}
	target, iface, _, warnings, err := interfaceForQuery(ctx, s, req.Execution, *req.Query)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.list.prepare")
	}
	list, err := iface.List(ctx, metav1.ListOptions{LabelSelector: req.Query.LabelSelector, FieldSelector: req.Query.FieldSelector})
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.list")
	}
	response := protocol.OperationResponse{Warnings: warnings.snapshot()}
	response.Resources = make([]protocol.ResourceResult, 0, len(list.Items))
	for i := range list.Items {
		item := &list.Items[i]
		raw, marshalErr := json.Marshal(item.Object)
		if marshalErr != nil {
			return protocol.OperationResponse{}, wireError(marshalErr, "kubectl.list.serialize")
		}
		response.Resources = append(response.Resources, protocol.ResourceResult{GVR: wireGVR(target.gvr), JSON: raw})
	}
	return response, nil
}

func createResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if strings.EqualFold(req.Preview, "client") {
		return protocol.OperationResponse{}, unsupported("kubectl.client-preview.create", "client-side create preview requires kubectl create machinery and is intentionally fail-closed in protocol v1")
	}
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("kubectl.resource-required", "resource identity is required")
	}
	obj, err := decodeObject(req.Payload)
	if err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.create.payload", err.Error())
	}
	target, iface, namespace, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.create.prepare")
	}
	if err := bindIdentity(obj, req.Resource.Name, namespace, target.namespaced); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.create.identity", err.Error())
	}
	if err := validatePayloadType(obj, target); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.create.type", err.Error())
	}
	options := metav1.CreateOptions{FieldManager: req.FieldManager, FieldValidation: fieldValidation(req.Execution.FieldValidation)}
	if strings.EqualFold(req.Preview, "server") {
		options.DryRun = []string{metav1.DryRunAll}
	}
	created, err := iface.Create(ctx, obj, options, subresourceArgs(req.Resource.Subresource)...)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.create")
	}
	return resultForObject(target, created, warnings, "kubectl.create.serialize")
}

func replaceResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if strings.EqualFold(req.Preview, "client") {
		return protocol.OperationResponse{}, unsupported("kubectl.client-preview.replace", "client-side replace preview is not approximated by a server operation")
	}
	if strings.EqualFold(req.Concurrency.Mode, "force") {
		return protocol.OperationResponse{}, unsupported("kubectl.replace-force", "replace has no portable forced-overwrite semantic")
	}
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("kubectl.resource-required", "resource identity is required")
	}
	obj, err := decodeObject(req.Payload)
	if err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.replace.payload", err.Error())
	}
	target, iface, namespace, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.replace.prepare")
	}
	if err := bindIdentity(obj, req.Resource.Name, namespace, target.namespaced); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.replace.identity", err.Error())
	}
	if err := validatePayloadType(obj, target); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.replace.type", err.Error())
	}
	if strings.EqualFold(req.Concurrency.Mode, "requireunchanged") {
		if req.Concurrency.ExpectedResourceVersion == "" {
			return protocol.OperationResponse{}, invalid("concurrency.resource-version-required", "RequireUnchanged needs ExpectedResourceVersion")
		}
		obj.SetResourceVersion(req.Concurrency.ExpectedResourceVersion)
	}
	options := metav1.UpdateOptions{FieldManager: req.FieldManager, FieldValidation: fieldValidation(req.Execution.FieldValidation)}
	if strings.EqualFold(req.Preview, "server") {
		options.DryRun = []string{metav1.DryRunAll}
	}
	updated, err := iface.Update(ctx, obj, options, subresourceArgs(req.Resource.Subresource)...)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.replace")
	}
	return resultForObject(target, updated, warnings, "kubectl.replace.serialize")
}

func patchResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if strings.EqualFold(req.Preview, "client") {
		return protocol.OperationResponse{}, unsupported("kubectl.client-preview.patch", "generic client-side patch preview is not approximated by server-side patch")
	}
	if !strings.EqualFold(req.Concurrency.Mode, "") && !strings.EqualFold(req.Concurrency.Mode, "default") {
		return protocol.OperationResponse{}, unsupported("kubectl.patch-concurrency", "generic patch has no backend-neutral resourceVersion precondition in protocol v1")
	}
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("kubectl.resource-required", "resource identity is required")
	}
	target, iface, _, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.patch.prepare")
	}
	patchType, ok := mapPatchType(req.PatchType)
	if !ok {
		return protocol.OperationResponse{}, invalid("kubectl.patch-type", "unknown patch type")
	}
	options := metav1.PatchOptions{FieldManager: req.FieldManager, FieldValidation: fieldValidation(req.Execution.FieldValidation)}
	if strings.EqualFold(req.Preview, "server") {
		options.DryRun = []string{metav1.DryRunAll}
	}
	patched, err := iface.Patch(ctx, req.Resource.Name, patchType, req.Payload, options, subresourceArgs(req.Resource.Subresource)...)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.patch")
	}
	return resultForObject(target, patched, warnings, "kubectl.patch.serialize")
}

func deleteResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if strings.EqualFold(req.Preview, "client") {
		return protocol.OperationResponse{}, unsupported("kubectl.client-preview.delete", "client-side delete preview is not approximated by a server operation")
	}
	if strings.EqualFold(req.Concurrency.Mode, "force") {
		return protocol.OperationResponse{}, unsupported("kubectl.delete-concurrency-force", "concurrency Force is distinct from deletion Force and is not defined for generic delete")
	}
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("kubectl.resource-required", "resource identity is required")
	}
	_, iface, _, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.delete.prepare")
	}
	options := metav1.DeleteOptions{}
	if strings.EqualFold(req.Preview, "server") {
		options.DryRun = []string{metav1.DryRunAll}
	}
	if req.Force {
		zero := int64(0)
		options.GracePeriodSeconds = &zero
	} else if req.GracePeriodSeconds != nil {
		options.GracePeriodSeconds = req.GracePeriodSeconds
	}
	if strings.EqualFold(req.Concurrency.Mode, "requireunchanged") {
		if req.Concurrency.ExpectedResourceVersion == "" {
			return protocol.OperationResponse{}, invalid("concurrency.resource-version-required", "RequireUnchanged needs ExpectedResourceVersion")
		}
		rv := req.Concurrency.ExpectedResourceVersion
		options.Preconditions = &metav1.Preconditions{ResourceVersion: &rv}
	}
	if err := iface.Delete(ctx, req.Resource.Name, options, subresourceArgs(req.Resource.Subresource)...); err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.delete")
	}
	return protocol.OperationResponse{Warnings: warnings.snapshot()}, nil
}

func interfaceForRef(ctx context.Context, s *session, exec protocol.ExecutionContext, ref protocol.ResourceRef, allowAll bool) (resolvedResource, dynamic.ResourceInterface, string, *warningCollector, error) {
	target, err := resolve(ctx, s, exec, ref.GVR, false)
	if err != nil {
		return resolvedResource{}, nil, "", nil, err
	}
	namespace, err := scopeNamespace(ref.Namespace, target.namespaced, s.defaultNamespace(), allowAll)
	if err != nil {
		return resolvedResource{}, nil, "", nil, err
	}
	cfg, warnings := operationConfig(ctx, s, exec)
	client, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return resolvedResource{}, nil, "", nil, err
	}
	namespaceable := client.Resource(target.gvr)
	if target.namespaced {
		return target, namespaceable.Namespace(namespace), namespace, warnings, nil
	}
	return target, namespaceable, "", warnings, nil
}

func interfaceForQuery(ctx context.Context, s *session, exec protocol.ExecutionContext, query protocol.Query) (resolvedResource, dynamic.ResourceInterface, string, *warningCollector, error) {
	target, err := resolve(ctx, s, exec, query.GVR, false)
	if err != nil {
		return resolvedResource{}, nil, "", nil, err
	}
	namespace, err := scopeNamespace(query.Namespace, target.namespaced, s.defaultNamespace(), true)
	if err != nil {
		return resolvedResource{}, nil, "", nil, err
	}
	cfg, warnings := operationConfig(ctx, s, exec)
	client, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return resolvedResource{}, nil, "", nil, err
	}
	namespaceable := client.Resource(target.gvr)
	if target.namespaced && !strings.EqualFold(query.Namespace.Kind, "all") {
		return target, namespaceable.Namespace(namespace), namespace, warnings, nil
	}
	return target, namespaceable, namespace, warnings, nil
}

func decodeObject(raw json.RawMessage) (*unstructured.Unstructured, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("Kubernetes resource payload is empty")
	}
	var object map[string]any
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, err
	}
	return &unstructured.Unstructured{Object: object}, nil
}

func bindIdentity(obj *unstructured.Unstructured, name, namespace string, namespaced bool) error {
	if name != "" {
		if existing := obj.GetName(); existing != "" && existing != name {
			return fmt.Errorf("payload metadata.name %q does not match operation identity %q", existing, name)
		}
		obj.SetName(name)
	}
	if namespaced {
		if existing := obj.GetNamespace(); existing != "" && existing != namespace {
			return fmt.Errorf("payload metadata.namespace %q does not match resolved namespace %q", existing, namespace)
		}
		obj.SetNamespace(namespace)
	} else if obj.GetNamespace() != "" {
		return fmt.Errorf("cluster-scoped payload must not set metadata.namespace")
	}
	return nil
}

func validatePayloadType(object interface {
	GroupVersionKind() schema.GroupVersionKind
}, target resolvedResource) error {
	actual := object.GroupVersionKind()
	if actual.Version == "" || actual.Kind == "" {
		return fmt.Errorf("resource payload must contain apiVersion and kind")
	}
	if actual != target.gvk {
		return fmt.Errorf("payload type %s does not match resolved resource type %s", actual.String(), target.gvk.String())
	}
	return nil
}

func resultForObject(target resolvedResource, obj *unstructured.Unstructured, warnings *warningCollector, code string) (protocol.OperationResponse, *protocol.WireError) {
	raw, err := json.Marshal(obj.Object)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, code)
	}
	return protocol.OperationResponse{Resources: []protocol.ResourceResult{{GVR: wireGVR(target.gvr), JSON: raw}}, Warnings: warnings.snapshot()}, nil
}

func wireGVR(gvr schema.GroupVersionResource) protocol.GVR {
	return protocol.GVR{Group: gvr.Group, Version: gvr.Version, Resource: gvr.Resource}
}
func subresourceArgs(value string) []string {
	if value == "" {
		return nil
	}
	return []string{value}
}
func fieldValidation(value string) string {
	switch strings.ToLower(value) {
	case "ignore":
		return "Ignore"
	case "warn":
		return "Warn"
	case "strict":
		return "Strict"
	default:
		return ""
	}
}
func mapPatchType(value string) (types.PatchType, bool) {
	switch strings.ToLower(value) {
	case "merge", "":
		return types.MergePatchType, true
	case "json":
		return types.JSONPatchType, true
	case "strategic":
		return types.StrategicMergePatchType, true
	default:
		return "", false
	}
}
