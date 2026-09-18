package kube

import (
	"bytes"
	"context"
	"fmt"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"github.com/spf13/cobra"
	"k8s.io/cli-runtime/pkg/genericiooptions"
	"k8s.io/kubectl/pkg/cmd/cp"
	cmdutil "k8s.io/kubectl/pkg/cmd/util"
)

func copyFiles(ctx context.Context, s *session, request protocol.CopyRequest) (protocol.CopyResponse, *protocol.WireError) {
	if strings.TrimSpace(request.Pod) == "" || strings.TrimSpace(request.LocalPath) == "" || strings.TrimSpace(request.RemotePath) == "" {
		return protocol.CopyResponse{}, invalid("copy.request", "pod, localPath and remotePath are required")
	}
	namespace, err := scopeNamespace(request.Namespace, true, s.defaultNamespace(), false)
	if err != nil {
		return protocol.CopyResponse{}, wireError(err, "copy.namespace")
	}
	getter, _, err := newRequestClientGetter(ctx, s, request.Execution, namespace, true)
	if err != nil {
		return protocol.CopyResponse{}, wireError(err, "copy.client")
	}
	factory := cmdutil.NewFactory(getter)
	var stdout, stderr bytes.Buffer
	options := cp.NewCopyOptions(genericiooptions.IOStreams{Out: &stdout, ErrOut: &stderr})
	options.Container = request.Container
	remote := fmt.Sprintf("%s/%s:%s", namespace, request.Pod, request.RemotePath)
	args := []string{remote, request.LocalPath}
	if request.ToPod {
		args = []string{request.LocalPath, remote}
	}
	command := &cobra.Command{Use: "cp"}
	if err := options.Complete(factory, command, args); err != nil {
		return protocol.CopyResponse{}, wireError(err, "copy.complete")
	}
	if err := options.Validate(); err != nil {
		return protocol.CopyResponse{}, invalid("copy.validate", err.Error())
	}
	if err := options.Run(); err != nil {
		return protocol.CopyResponse{}, wireError(err, "copy.run")
	}
	return protocol.CopyResponse{Output: stdout.String(), ErrorOutput: stderr.String()}, nil
}
