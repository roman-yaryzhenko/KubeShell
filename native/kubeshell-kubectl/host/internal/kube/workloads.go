package kube

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/cli-runtime/pkg/resource"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/restmapper"
	cmdset "k8s.io/kubectl/pkg/cmd/set"
	cmdutil "k8s.io/kubectl/pkg/cmd/util"
	"k8s.io/kubectl/pkg/polymorphichelpers"
	"k8s.io/kubectl/pkg/scheme"
)

// rolloutRestart keeps kubectl's workload-specific restart validation (including paused
// Deployments) while retaining KubeShell's typed operation boundary. Cobra command wrappers are
// deliberately not involved: only the reviewed polymorphic helper and strategic-merge patch are used.
func rolloutRestart(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	return mutateWorkload(ctx, s, req, "rollout.restart", cmdset.PatchFn(polymorphichelpers.ObjectRestarterFn))
}

func setImage(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if strings.TrimSpace(req.Container) == "" || strings.TrimSpace(req.Image) == "" {
		return protocol.OperationResponse{}, invalid("set-image.arguments", "container and image are required")
	}
	mutate := func(obj runtime.Object) ([]byte, error) {
		found, err := polymorphichelpers.UpdatePodSpecForObjectFn(obj, func(spec *corev1.PodSpec) error {
			matched := setContainerImage(spec.InitContainers, req.Container, req.Image)
			if setContainerImage(spec.Containers, req.Container, req.Image) {
				matched = true
			}
			if !matched {
				return fmt.Errorf("unable to find container named %q", req.Container)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
		if !found {
			return nil, fmt.Errorf("resource does not expose a pod template")
		}
		return runtime.Encode(scheme.DefaultJSONEncoder(), obj)
	}
	return mutateWorkload(ctx, s, req, "set-image", mutate)
}

func setContainerImage(containers []corev1.Container, name, image string) bool {
	found := false
	for i := range containers {
		if name == "*" || containers[i].Name == name {
			containers[i].Image = image
			found = true
		}
	}
	return found
}

func mutateWorkload(ctx context.Context, s *session, req protocol.OperationRequest, code string, mutate cmdset.PatchFn) (protocol.OperationResponse, *protocol.WireError) {
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid(code+".resource-required", "workload identity is required")
	}
	target, iface, _, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, code+".prepare")
	}
	current, err := iface.Get(ctx, req.Resource.Name, metav1.GetOptions{})
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, code+".get")
	}
	typed, err := decodeTypedObject(current)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, code+".decode")
	}
	patch := &cmdset.Patch{Info: &resource.Info{Object: typed}}
	if !cmdset.CalculatePatch(patch, scheme.DefaultJSONEncoder(), mutate) {
		return protocol.OperationResponse{}, invalid(code+".no-change", "workload mutation produced no change")
	}
	if patch.Err != nil {
		return protocol.OperationResponse{}, wireError(patch.Err, code+".patch")
	}
	if len(patch.Patch) == 0 || string(patch.Patch) == "{}" {
		return protocol.OperationResponse{}, invalid(code+".no-change", "workload mutation produced an empty patch")
	}

	switch strings.ToLower(req.Preview) {
	case "client":
		if !json.Valid(patch.After) {
			return protocol.OperationResponse{}, wireError(fmt.Errorf("upstream workload helper returned invalid JSON"), code+".client-preview")
		}
		return protocol.OperationResponse{Resources: []protocol.ResourceResult{{GVR: wireGVR(target.gvr), JSON: append([]byte(nil), patch.After...)}}, Warnings: warnings.snapshot()}, nil
	case "", "none", "server":
	default:
		return protocol.OperationResponse{}, invalid(code+".preview", fmt.Sprintf("unknown preview mode %q", req.Preview))
	}

	options := metav1.PatchOptions{FieldManager: req.FieldManager}
	if strings.EqualFold(req.Preview, "server") {
		options.DryRun = []string{metav1.DryRunAll}
	}
	updated, err := iface.Patch(ctx, req.Resource.Name, types.StrategicMergePatchType, patch.Patch, options)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, code)
	}
	return resultForObject(target, updated, warnings, code+".serialize")
}

func decodeTypedObject(value *unstructured.Unstructured) (runtime.Object, error) {
	raw, err := json.Marshal(value.Object)
	if err != nil {
		return nil, err
	}
	obj, _, err := scheme.Codecs.UniversalDeserializer().Decode(raw, nil, nil)
	return obj, err
}

func scaleResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if req.Resource == nil || req.Replicas == nil {
		return protocol.OperationResponse{}, invalid("scale.arguments", "resource identity and replica count are required")
	}
	if *req.Replicas < 0 {
		return protocol.OperationResponse{}, invalid("scale.replicas", "replica count must be greater than or equal to zero")
	}
	target, iface, namespace, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "scale.prepare")
	}
	current, err := iface.Get(ctx, req.Resource.Name, metav1.GetOptions{})
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "scale.get")
	}

	if strings.EqualFold(req.Preview, "client") {
		if err := unstructured.SetNestedField(current.Object, int64(*req.Replicas), "spec", "replicas"); err != nil {
			return protocol.OperationResponse{}, wireError(err, "scale.client-preview")
		}
		return resultForObject(target, current, warnings, "scale.client-preview.serialize")
	}
	if req.Preview != "" && !strings.EqualFold(req.Preview, "none") && !strings.EqualFold(req.Preview, "server") {
		return protocol.OperationResponse{}, invalid("scale.preview", fmt.Sprintf("unknown preview mode %q", req.Preview))
	}

	getter, scaleWarnings, err := newRequestClientGetter(ctx, s, req.Execution, namespace, target.namespaced)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "scale.client")
	}
	scales, err := cmdutil.ScaleClientFn(getter)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "scale.client")
	}
	data, _ := json.Marshal(map[string]any{"spec": map[string]any{"replicas": *req.Replicas}})
	options := metav1.PatchOptions{}
	if strings.EqualFold(req.Preview, "server") {
		options.DryRun = []string{metav1.DryRunAll}
	}
	if _, err := scales.Scales(namespace).Patch(ctx, target.gvr, req.Resource.Name, types.MergePatchType, data, options); err != nil {
		return protocol.OperationResponse{}, wireError(err, "scale")
	}
	warnings.messages = append(warnings.messages, scaleWarnings.snapshot()...)

	if strings.EqualFold(req.Preview, "server") {
		if err := unstructured.SetNestedField(current.Object, int64(*req.Replicas), "spec", "replicas"); err != nil {
			return protocol.OperationResponse{}, wireError(err, "scale.server-preview")
		}
		return resultForObject(target, current, warnings, "scale.server-preview.serialize")
	}
	updated, err := iface.Get(ctx, req.Resource.Name, metav1.GetOptions{})
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "scale.result")
	}
	return resultForObject(target, updated, warnings, "scale.serialize")
}

func newRequestClientGetter(ctx context.Context, s *session, exec protocol.ExecutionContext, namespace string, namespaced bool) (*requestClientGetter, *warningCollector, error) {
	config, warnings := operationConfig(ctx, s, exec)
	discoveryClient, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		return nil, warnings, err
	}
	cached := memory.NewMemCacheClient(discoveryClient)
	mapper := restmapper.NewShortcutExpander(restmapper.NewDeferredDiscoveryRESTMapper(cached), discoveryClient, nil)
	return &requestClientGetter{config: config, raw: s.clientConfigFor(namespace, namespaced), discovery: cached, mapper: mapper}, warnings, nil
}

func rolloutStatus(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("rollout.status.resource-required", "rollout status requires a resource identity")
	}
	target, iface, _, warnings, err := interfaceForRef(ctx, s, req.Execution, *req.Resource, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.status.prepare")
	}
	viewer, err := polymorphichelpers.StatusViewerFor(target.gvk.GroupKind())
	if err != nil {
		return protocol.OperationResponse{}, unsupported("rollout.status.kind", err.Error())
	}
	if req.WaitTimeoutMilliseconds <= 0 {
		req.WaitTimeoutMilliseconds = int64((5 * time.Minute) / time.Millisecond)
	}
	waitCtx, cancel := context.WithTimeout(ctx, time.Duration(req.WaitTimeoutMilliseconds)*time.Millisecond)
	defer cancel()

	var latest *unstructured.Unstructured
	var message string
	err = wait.PollUntilContextCancel(waitCtx, time.Second, true, func(inner context.Context) (bool, error) {
		obj, getErr := iface.Get(inner, req.Resource.Name, metav1.GetOptions{})
		if getErr != nil {
			return false, getErr
		}
		latest = obj
		status, done, statusErr := viewer.Status(obj, req.Revision)
		message = strings.TrimSpace(status)
		return done, statusErr
	})
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.status")
	}
	if latest == nil {
		return protocol.OperationResponse{}, wireError(fmt.Errorf("rollout status completed without a resource"), "rollout.status.result")
	}
	response, wireErr := resultForObject(target, latest, warnings, "rollout.status.serialize")
	if wireErr != nil {
		return protocol.OperationResponse{}, wireErr
	}
	if message != "" {
		response.Diagnostics = map[string]string{"rollout.status": message}
	}
	return response, nil
}
