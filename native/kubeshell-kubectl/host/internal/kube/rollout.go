package kube

import (
	"context"
	"fmt"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	cmdutil "k8s.io/kubectl/pkg/cmd/util"
	"k8s.io/kubectl/pkg/polymorphichelpers"
)

func rolloutUndo(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("rollout.undo.resource-required", "rollout undo requires a resource identity")
	}
	if req.ToRevision < 0 {
		return protocol.OperationResponse{}, invalid("rollout.undo.revision", "rollout revision must be zero (previous) or a positive revision")
	}

	resolved, err := resolve(ctx, s, req.Execution, req.Resource.GVR, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.undo.resolve")
	}
	if !resolved.namespaced {
		return protocol.OperationResponse{}, invalid("rollout.undo.scope", "rollout undo requires a namespaced workload")
	}
	namespace, err := scopeNamespace(req.Resource.Namespace, true, s.defaultNamespace(), false)
	if err != nil {
		return protocol.OperationResponse{}, invalid("rollout.undo.namespace", err.Error())
	}

	cfg, warnings := operationConfig(ctx, s, req.Execution)
	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.undo.client")
	}

	var object runtime.Object
	switch strings.ToLower(resolved.gvk.Kind) {
	case "deployment":
		object, err = clientset.AppsV1().Deployments(namespace).Get(ctx, req.Resource.Name, metav1GetOptions)
	case "daemonset":
		object, err = clientset.AppsV1().DaemonSets(namespace).Get(ctx, req.Resource.Name, metav1GetOptions)
	case "statefulset":
		object, err = clientset.AppsV1().StatefulSets(namespace).Get(ctx, req.Resource.Name, metav1GetOptions)
	default:
		return protocol.OperationResponse{}, unsupported("rollout.undo.kind", fmt.Sprintf("kubectl rollback machinery does not support %s", resolved.gvk.Kind))
	}
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.undo.get")
	}

	rollbacker, err := polymorphichelpers.RollbackerFor(resolved.gvk.GroupKind(), clientset)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.undo.rollbacker")
	}
	strategy, err := rollbackDryRun(req.Preview)
	if err != nil {
		return protocol.OperationResponse{}, invalid("rollout.undo.preview", err.Error())
	}
	message, err := rollbacker.Rollback(object, nil, req.ToRevision, strategy)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "rollout.undo")
	}

	response := protocol.OperationResponse{
		Warnings: warnings.snapshot(),
		Diagnostics: map[string]string{
			"rollout.undo": message,
		},
	}
	if strategy == cmdutil.DryRunClient {
		return response, nil
	}

	current, wireErr := getResource(ctx, s, protocol.OperationRequest{Resource: req.Resource, Execution: req.Execution})
	if wireErr != nil {
		return protocol.OperationResponse{}, wireErr
	}
	response.Resources = current.Resources
	response.Warnings = append(response.Warnings, current.Warnings...)
	return response, nil
}

func rollbackDryRun(value string) (cmdutil.DryRunStrategy, error) {
	switch strings.ToLower(value) {
	case "", "none":
		return cmdutil.DryRunNone, nil
	case "client":
		return cmdutil.DryRunClient, nil
	case "server":
		return cmdutil.DryRunServer, nil
	default:
		return cmdutil.DryRunNone, fmt.Errorf("unknown preview mode %q", value)
	}
}

// Keep a package-level zero value so typed GET calls stay allocation-free and explicit.
var metav1GetOptions = metav1.GetOptions{}
