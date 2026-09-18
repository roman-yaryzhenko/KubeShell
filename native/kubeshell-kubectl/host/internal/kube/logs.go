package kube

import (
	"bufio"
	"context"
	"errors"
	"io"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	ipcserver "github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/server"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
)

func startLogs(ctx context.Context, ops *operationManager, sessionID uint64, s *session, request protocol.LogRequest, stream ipcserver.StreamWriter) (protocol.OperationResponse, *protocol.WireError) {
	if strings.TrimSpace(request.Pod) == "" {
		return protocol.OperationResponse{}, invalid("logs.pod", "pod name is required")
	}
	namespace, err := scopeNamespace(request.Namespace, true, s.defaultNamespace(), false)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "logs.namespace")
	}
	config := s.configFor(request.Execution)
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "logs.client")
	}
	var tailLines *int64
	if request.TailLines >= 0 {
		tail := request.TailLines
		tailLines = &tail
	}
	options := &corev1.PodLogOptions{
		Container:  request.Container,
		Follow:     request.Follow,
		Previous:   request.Previous,
		Timestamps: request.Timestamps,
		TailLines:  tailLines,
	}
	if request.SinceSeconds > 0 {
		since := request.SinceSeconds
		options.SinceSeconds = &since
	}
	// Kubernetes API does not expose kubectl's presentation-only --prefix flag. Prefixing is done
	// while pumping lines so the wire remains a stream of complete text records.
	logCtx, cancel := context.WithCancel(ctx)
	reader, err := client.CoreV1().Pods(namespace).GetLogs(request.Pod, options).Stream(logCtx)
	if err != nil {
		cancel()
		return protocol.OperationResponse{}, wireError(err, "logs.stream")
	}
	id := ops.add(sessionID, cancel)
	go pumpLogs(logCtx, id, request.Pod, request.Container, request.Prefix, reader, ops, stream)
	return protocol.OperationResponse{OperationID: id}, nil
}

func pumpLogs(ctx context.Context, id uint64, pod, container string, prefix bool, reader io.ReadCloser, ops *operationManager, stream ipcserver.StreamWriter) {
	defer ops.done(id)
	defer reader.Close()
	defer func() { _ = stream.End(protocol.StreamEnd{OperationID: id}) }()

	buffered := bufio.NewReaderSize(reader, 64*1024)
	for {
		line, err := buffered.ReadString('\n')
		if len(line) != 0 {
			line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
			if prefix {
				label := pod
				if container != "" {
					label += "/" + container
				}
				line = label + " " + line
			}
			if sendErr := stream.Item(protocol.StreamItem{OperationID: id, EventType: "log", Text: line}); sendErr != nil {
				return
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, context.Canceled) || ctx.Err() != nil {
				return
			}
			_ = stream.Item(protocol.StreamItem{OperationID: id, EventType: "error", Error: wireError(err, "logs.read")})
			return
		}
	}
}
