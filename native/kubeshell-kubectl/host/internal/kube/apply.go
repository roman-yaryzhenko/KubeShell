package kube

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"github.com/spf13/cobra"
	"k8s.io/cli-runtime/pkg/genericiooptions"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/restmapper"
	cmdapply "k8s.io/kubectl/pkg/cmd/apply"
	cmdutil "k8s.io/kubectl/pkg/cmd/util"
)

func applyResource(ctx context.Context, s *session, req protocol.OperationRequest) (protocol.OperationResponse, *protocol.WireError) {
	if req.Resource == nil {
		return protocol.OperationResponse{}, invalid("kubectl.resource-required", "resource identity is required")
	}
	serverSide := strings.EqualFold(req.ApplyStrategy, "serverside")
	clientSide := req.ApplyStrategy == "" || strings.EqualFold(req.ApplyStrategy, "clientside")
	if !serverSide && !clientSide {
		return protocol.OperationResponse{}, invalid("kubectl.apply.strategy", "unknown apply strategy")
	}
	if serverSide && strings.EqualFold(req.Preview, "client") {
		return protocol.OperationResponse{}, invalid("kubectl.apply.preview", "client preview is invalid for server-side apply")
	}
	if req.ForceConflicts && !serverSide {
		return protocol.OperationResponse{}, invalid("kubectl.apply.force-conflicts", "force conflicts requires server-side apply")
	}
	if req.Resource.Subresource != "" && !serverSide {
		return protocol.OperationResponse{}, unsupported("kubectl.apply.client-subresource", "kubectl apply supports subresources only with server-side apply")
	}

	target, err := resolve(ctx, s, req.Execution, req.Resource.GVR, false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.apply.resolve")
	}
	namespace, err := scopeNamespace(req.Resource.Namespace, target.namespaced, s.defaultNamespace(), false)
	if err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.apply.namespace", err.Error())
	}

	object, err := decodeObject(req.Payload)
	if err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.apply.payload", err.Error())
	}
	if err := bindIdentity(object, req.Resource.Name, namespace, target.namespaced); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.apply.identity", err.Error())
	}
	if err := validatePayloadType(object, target); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.apply.type", err.Error())
	}
	payload, err := json.Marshal(object.Object)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.apply.payload-serialization")
	}

	config, warnings := operationConfig(ctx, s, req.Execution)
	discoveryClient, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.apply.discovery")
	}
	cachedDiscovery := memory.NewMemCacheClient(discoveryClient)
	mapper := restmapper.NewShortcutExpander(restmapper.NewDeferredDiscoveryRESTMapper(cachedDiscovery), discoveryClient, nil)
	rawConfig := s.clientConfigFor(namespace, target.namespaced)
	getter := &requestClientGetter{config: config, raw: rawConfig, discovery: cachedDiscovery, mapper: mapper}
	factory := cmdutil.NewFactory(getter)

	var stdout, stderr bytes.Buffer
	streams := genericiooptions.IOStreams{In: bytes.NewReader(payload), Out: &stdout, ErrOut: &stderr}
	flags := cmdapply.NewApplyFlags(streams)
	command := &cobra.Command{Use: "apply"}
	flags.AddFlags(command)

	set := func(name, value string) *protocol.WireError {
		if err := command.Flags().Set(name, value); err != nil {
			return invalid("kubectl.apply.flag", fmt.Sprintf("cannot set apply option %s: %v", name, err))
		}
		return nil
	}
	for name, value := range map[string]string{"filename": "-", "output": "json"} {
		if wireErr := set(name, value); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
	}
	if req.FieldManager != "" {
		if wireErr := set("field-manager", req.FieldManager); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
	}
	switch strings.ToLower(req.Preview) {
	case "client":
		if wireErr := set("dry-run", "client"); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
	case "server":
		if wireErr := set("dry-run", "server"); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
	case "", "none":
	default:
		return protocol.OperationResponse{}, invalid("kubectl.apply.preview", "unknown apply preview mode")
	}
	if serverSide {
		if wireErr := set("server-side", "true"); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
		if req.ForceConflicts {
			if wireErr := set("force-conflicts", "true"); wireErr != nil {
				return protocol.OperationResponse{}, wireErr
			}
		}
	}
	if req.Resource.Subresource != "" {
		if wireErr := set("subresource", req.Resource.Subresource); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
	}
	if validation := strings.ToLower(fieldValidation(req.Execution.FieldValidation)); validation != "" {
		if wireErr := set("validate", validation); wireErr != nil {
			return protocol.OperationResponse{}, wireErr
		}
	}

	options, err := flags.ToOptions(factory, command, "KubeShell", nil)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.apply.options")
	}
	if err := options.Validate(); err != nil {
		return protocol.OperationResponse{}, invalid("kubectl.apply.validation", err.Error())
	}

	// Upstream ApplyOptions currently does not accept context.Context. operationConfig binds the
	// REST transport to the IPC request context, so cancellation still interrupts HTTP work instead
	// of allowing an abandoned apply mutation to continue in the helper process.
	if err := options.Run(); err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.apply")
	}

	raw := bytes.TrimSpace(stdout.Bytes())
	response := protocol.OperationResponse{Warnings: append(warnings.snapshot(), stderrLines(stderr.String())...)}
	if len(raw) == 0 {
		return response, nil
	}
	if !json.Valid(raw) {
		return protocol.OperationResponse{}, wireError(fmt.Errorf("kubectl apply produced non-JSON output: %s", raw), "kubectl.apply.output")
	}
	response.Resources = []protocol.ResourceResult{{GVR: wireGVR(target.gvr), JSON: append([]byte(nil), raw...)}}
	return response, nil
}

func stderrLines(value string) []string {
	lines := strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n")
	result := make([]string, 0, len(lines))
	for _, line := range lines {
		if text := strings.TrimSpace(line); text != "" {
			result = append(result, text)
		}
	}
	return result
}
