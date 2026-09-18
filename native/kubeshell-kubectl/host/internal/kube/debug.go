package kube

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"github.com/spf13/cobra"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/cli-runtime/pkg/genericiooptions"
	"k8s.io/client-go/kubernetes"
	corev1client "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/tools/cache"
	watchtools "k8s.io/client-go/tools/watch"
	cmddebug "k8s.io/kubectl/pkg/cmd/debug"
)

// debugResource embeds kubectl's reviewed DebugOptions implementation while keeping terminal I/O
// outside the long-lived host. The request intentionally models the wider kubectl debug surface so
// future KubeShell cmdlets can expose copy-to/custom-profile/set-image semantics without changing
// the protocol shape again.
func debugResource(ctx context.Context, s *session, req protocol.DebugRequest) (protocol.DebugResponse, *protocol.WireError) {
	if strings.TrimSpace(req.Target.Name) == "" || strings.TrimSpace(req.Target.GVR.Resource) == "" {
		return protocol.DebugResponse{}, invalid("debug.target", "debug target resource and name are required")
	}

	target, err := resolve(ctx, s, req.Execution, req.Target.GVR, false)
	if err != nil {
		return protocol.DebugResponse{}, wireError(err, "debug.resolve")
	}
	// The wire contract deliberately accepts a generic ResourceIdentity so a future kubectl host can
	// add target kinds without another ABI change. kubectl 0.37 itself implements debug only for
	// core/v1 Pods and Nodes, so classify other resolved kinds as semantic unsupported here.
	if target.gvk.Group != "" || target.gvk.Version != "v1" || (target.gvk.Kind != "Pod" && target.gvk.Kind != "Node") {
		return protocol.DebugResponse{}, unsupported("debug.kind", fmt.Sprintf("%s is not supported by kubectl 0.37 debug", target.gvk.String()))
	}
	targetNamespace, err := scopeNamespace(req.Target.Namespace, target.namespaced, s.defaultNamespace(), false)
	if err != nil {
		return protocol.DebugResponse{}, invalid("debug.namespace", err.Error())
	}
	// Node debug still creates a Pod in the selected/default namespace even though the target itself
	// is cluster-scoped. A namespaced raw loader is therefore correct for both Pod and Node targets.
	debugNamespace := targetNamespace
	if !target.namespaced {
		debugNamespace = s.defaultNamespace()
	}

	getter, serverWarnings, err := newRequestClientGetter(ctx, s, req.Execution, debugNamespace, true)
	if err != nil {
		return protocol.DebugResponse{}, wireError(err, "debug.client")
	}
	client, err := kubernetes.NewForConfig(getter.config)
	if err != nil {
		return protocol.DebugResponse{}, wireError(err, "debug.client")
	}

	var stdout, stderr bytes.Buffer
	streams := genericiooptions.IOStreams{Out: &stdout, ErrOut: &stderr}
	options := cmddebug.NewDebugOptions(streams)
	root := &cobra.Command{Use: "kubeshell"}
	command := &cobra.Command{Use: "debug"}
	root.AddCommand(command)
	options.AddFlags(command)

	if wireErr := configureDebugFlags(command, req); wireErr != nil {
		return protocol.DebugResponse{}, wireErr
	}
	targetArg := target.gvr.Resource + "/" + req.Target.Name
	if err := options.Complete(getter, command, []string{targetArg}); err != nil {
		return protocol.DebugResponse{}, wireError(err, "debug.complete")
	}
	options.Args = append([]string(nil), req.Command...)
	options.ArgsOnly = req.ArgumentsOnly
	options.SetImages = cloneStringMap(req.SetImages)
	options.Env = debugEnv(req.Environment)
	if req.CustomProfileJSON != "" {
		var custom corev1.Container
		if err := json.Unmarshal([]byte(req.CustomProfileJSON), &custom); err != nil {
			return protocol.DebugResponse{}, invalid("debug.custom-profile", "custom profile must be a Kubernetes Container JSON object: "+err.Error())
		}
		options.CustomProfile = &custom
	}
	if err := options.Validate(); err != nil {
		return protocol.DebugResponse{}, invalid("debug.validate", err.Error())
	}

	return runDebugOptions(ctx, getter, command, options, req, client.CoreV1(), target, debugNamespace, serverWarnings, &stdout, &stderr)
}

func runDebugOptions(
	ctx context.Context,
	getter *requestClientGetter,
	command *cobra.Command,
	options *cmddebug.DebugOptions,
	req protocol.DebugRequest,
	core corev1client.CoreV1Interface,
	target resolvedResource,
	debugNamespace string,
	serverWarnings *warningCollector,
	stdout, stderr *bytes.Buffer,
) (protocol.DebugResponse, *protocol.WireError) {
	desiredAttach := options.Attach
	var attachment *protocol.DebugAttachment
	var capturedPod *corev1.Pod

	options.AttachFunc = func(_ context.Context, _ genericclioptions.RESTClientGetter, _ string, namespace, podName, containerName string) error {
		attachment = &protocol.DebugAttachment{
			Namespace: namespace, Pod: podName, Container: containerName,
			Continuation: "none", Interactive: options.Interactive, TTY: options.TTY, Quiet: options.Quiet,
		}
		if !desiredAttach {
			return nil
		}
		pod, continuation, err := waitForDebugContainer(ctx, core, namespace, podName, containerName)
		if err != nil {
			return err
		}
		capturedPod = pod
		attachment.Continuation = continuation
		return nil
	}

	// Run invokes AttachFunc only after the mutation has produced a concrete Pod/container. Force
	// this internal callback even when the caller did not request terminal attach; desiredAttach above
	// remains the user-visible behavior and controls whether readiness is awaited.
	options.Attach = true
	if err := options.Run(getter, command); err != nil {
		return protocol.DebugResponse{}, wireError(err, "debug.run")
	}

	if capturedPod == nil {
		var namespace, podName string
		switch {
		case attachment != nil:
			namespace, podName = attachment.Namespace, attachment.Pod
		case req.CopyTo != "":
			namespace, podName = debugNamespace, req.CopyTo
		case target.gvr.Group == "" && target.gvr.Version == "v1" && target.gvr.Resource == "pods":
			namespace, podName = debugNamespace, req.Target.Name
		}
		if podName != "" {
			pod, err := core.Pods(namespace).Get(ctx, podName, metav1.GetOptions{})
			if err != nil {
				return protocol.DebugResponse{}, wireError(err, "debug.result")
			}
			capturedPod = pod
		}
	}

	response := protocol.DebugResponse{
		Attachment: attachment,
		Warnings:   append(serverWarnings.snapshot(), stderrLines(stderr.String())...),
		Output:     strings.TrimSpace(stdout.String()),
	}
	if capturedPod != nil {
		raw, err := json.Marshal(capturedPod)
		if err != nil {
			return protocol.DebugResponse{}, wireError(err, "debug.serialize")
		}
		response.Resource = &protocol.ResourceResult{GVR: protocol.GVR{Version: "v1", Resource: "pods"}, JSON: raw}
	}
	return response, nil
}

func configureDebugFlags(command *cobra.Command, req protocol.DebugRequest) *protocol.WireError {
	set := func(name, value string) *protocol.WireError {
		if err := command.Flags().Set(name, value); err != nil {
			return invalid("debug.flag", fmt.Sprintf("cannot set debug option %s: %v", name, err))
		}
		return nil
	}
	values := map[string]string{
		"image": req.Image, "container": req.Container, "copy-to": req.CopyTo,
		"target": req.TargetContainer, "profile": req.Profile, "image-pull-policy": req.ImagePullPolicy,
	}
	for name, value := range values {
		if value != "" {
			if e := set(name, value); e != nil {
				return e
			}
		}
	}
	bools := map[string]bool{
		"replace": req.Replace, "stdin": req.Interactive, "tty": req.TTY, "quiet": req.Quiet,
		"keep-labels": req.KeepLabels, "keep-annotations": req.KeepAnnotations,
		"keep-liveness": req.KeepLiveness, "keep-readiness": req.KeepReadiness,
		"keep-startup": req.KeepStartup, "same-node": req.SameNode,
	}
	for name, value := range bools {
		if value {
			if e := set(name, "true"); e != nil {
				return e
			}
		}
	}
	if req.Attach != nil {
		if e := set("attach", strconv.FormatBool(*req.Attach)); e != nil {
			return e
		}
	}
	if req.ShareProcesses != nil {
		if e := set("share-processes", strconv.FormatBool(*req.ShareProcesses)); e != nil {
			return e
		}
	}
	if req.KeepInitContainers != nil {
		if e := set("keep-init-containers", strconv.FormatBool(*req.KeepInitContainers)); e != nil {
			return e
		}
	}
	return nil
}

func debugEnv(values map[string]string) []corev1.EnvVar {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := make([]corev1.EnvVar, 0, len(keys))
	for _, key := range keys {
		out = append(out, corev1.EnvVar{Name: key, Value: values[key]})
	}
	return out
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	out := make(map[string]string, len(values))
	for key, value := range values {
		out[key] = value
	}
	return out
}

func waitForDebugContainer(ctx context.Context, core corev1client.CoreV1Interface, namespace, podName, containerName string) (*corev1.Pod, string, error) {
	// Fast-path the current Pod state before starting a watch. Besides avoiding an
	// unnecessary watch for already-running debug containers, this also closes the
	// list/watch race where the state became ready immediately before the watch was
	// established.
	pod, err := core.Pods(namespace).Get(ctx, podName, metav1.GetOptions{})
	if err != nil {
		return nil, "", err
	}
	if continuation, ready := debugContinuation(pod, containerName); ready {
		return pod, continuation, nil
	}

	selector := fields.OneTermEqualSelector("metadata.name", podName).String()
	lw := &cache.ListWatch{
		ListFunc: func(options metav1.ListOptions) (runtime.Object, error) {
			options.FieldSelector = selector
			return core.Pods(namespace).List(ctx, options)
		},
		WatchFunc: func(options metav1.ListOptions) (watch.Interface, error) {
			options.FieldSelector = selector
			return core.Pods(namespace).Watch(ctx, options)
		},
	}
	event, err := watchtools.UntilWithSync(ctx, lw, &corev1.Pod{}, nil, func(event watch.Event) (bool, error) {
		if event.Type == watch.Deleted {
			return false, apierrors.NewNotFound(schema.GroupResource{Resource: "pods"}, podName)
		}
		pod, ok := event.Object.(*corev1.Pod)
		if !ok {
			return false, fmt.Errorf("debug readiness watch returned %T instead of Pod", event.Object)
		}
		status := debugContainerStatus(pod, containerName)
		return status != nil && (status.State.Running != nil || status.State.Terminated != nil), nil
	})
	if err != nil {
		return nil, "", err
	}
	if event == nil {
		return nil, "", fmt.Errorf("debug readiness watch ended without a Pod")
	}
	pod, ok := event.Object.(*corev1.Pod)
	if !ok {
		return nil, "", fmt.Errorf("debug readiness watch returned %T instead of Pod", event.Object)
	}
	continuation, ready := debugContinuation(pod, containerName)
	if !ready {
		return nil, "", fmt.Errorf("debug container %q has no running or terminated status", containerName)
	}
	return pod, continuation, nil
}

func debugContinuation(pod *corev1.Pod, containerName string) (string, bool) {
	status := debugContainerStatus(pod, containerName)
	if status == nil {
		return "", false
	}
	if status.State.Terminated != nil {
		return "logs", true
	}
	if status.State.Running != nil {
		return "attach", true
	}
	return "", false
}

func debugContainerStatus(pod *corev1.Pod, name string) *corev1.ContainerStatus {
	groups := [][]corev1.ContainerStatus{pod.Status.InitContainerStatuses, pod.Status.ContainerStatuses, pod.Status.EphemeralContainerStatuses}
	for _, statuses := range groups {
		for i := range statuses {
			if statuses[i].Name == name {
				return &statuses[i]
			}
		}
	}
	return nil
}
