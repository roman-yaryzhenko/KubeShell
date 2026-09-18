package kube

import (
	"context"
	"testing"
	"time"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"github.com/spf13/cobra"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/cli-runtime/pkg/genericiooptions"
	"k8s.io/client-go/kubernetes/fake"
	cmddebug "k8s.io/kubectl/pkg/cmd/debug"
)

func TestConfigureDebugFlagsPreservesExplicitFalse(t *testing.T) {
	attach, share, keepInit := false, false, false
	options := cmddebug.NewDebugOptions(genericiooptions.IOStreams{})
	command := &cobra.Command{Use: "debug"}
	options.AddFlags(command)
	req := protocol.DebugRequest{Attach: &attach, ShareProcesses: &share, KeepInitContainers: &keepInit, Profile: "general"}
	if wireErr := configureDebugFlags(command, req); wireErr != nil {
		t.Fatal(wireErr.Message)
	}
	for _, name := range []string{"attach", "share-processes", "keep-init-containers"} {
		flag := command.Flags().Lookup(name)
		if flag == nil || !flag.Changed || flag.Value.String() != "false" {
			t.Fatalf("flag %s must be explicitly changed to false: %#v", name, flag)
		}
	}
}

func TestConfigureDebugFlagsCoversFutureDebugSurface(t *testing.T) {
	attach, share, keepInit := true, false, true
	options := cmddebug.NewDebugOptions(genericiooptions.IOStreams{})
	command := &cobra.Command{Use: "debug"}
	options.AddFlags(command)
	req := protocol.DebugRequest{
		Image: "example/debug:1", Container: "debugger", CopyTo: "pod-copy", Replace: true,
		Interactive: true, TTY: true, Quiet: true, KeepLabels: true, KeepAnnotations: true,
		KeepLiveness: true, KeepReadiness: true, KeepStartup: true, KeepInitContainers: &keepInit,
		SameNode: true, ShareProcesses: &share, TargetContainer: "app", Profile: "future-profile",
		ImagePullPolicy: "IfNotPresent", Attach: &attach,
	}
	if wireErr := configureDebugFlags(command, req); wireErr != nil {
		t.Fatal(wireErr.Message)
	}
	want := map[string]string{
		"image": "example/debug:1", "container": "debugger", "copy-to": "pod-copy", "replace": "true",
		"stdin": "true", "tty": "true", "quiet": "true", "keep-labels": "true", "keep-annotations": "true",
		"keep-liveness": "true", "keep-readiness": "true", "keep-startup": "true", "keep-init-containers": "true",
		"same-node": "true", "share-processes": "false", "target": "app", "profile": "future-profile",
		"image-pull-policy": "IfNotPresent", "attach": "true",
	}
	for name, value := range want {
		flag := command.Flags().Lookup(name)
		if flag == nil || !flag.Changed || flag.Value.String() != value {
			t.Fatalf("flag %s=%v, want changed value %q", name, flag, value)
		}
	}
}

func TestDebugEnvHasStableOrdering(t *testing.T) {
	got := debugEnv(map[string]string{"Z": "last", "A": "first", "M": "middle"})
	if len(got) != 3 || got[0].Name != "A" || got[1].Name != "M" || got[2].Name != "Z" {
		t.Fatalf("debug env ordering is not stable: %#v", got)
	}
}

func TestDebugContainerStatusIncludesEphemeralContainers(t *testing.T) {
	pod := &corev1.Pod{Status: corev1.PodStatus{EphemeralContainerStatuses: []corev1.ContainerStatus{{
		Name: "debugger", State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 0}},
	}}}}
	status := debugContainerStatus(pod, "debugger")
	if status == nil || status.State.Terminated == nil {
		t.Fatal("ephemeral debug container status was not found")
	}
}

func TestWaitForDebugContainerReturnsAttachForRunningContainer(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "demo", Namespace: "ns"},
		Status: corev1.PodStatus{EphemeralContainerStatuses: []corev1.ContainerStatus{{
			Name: "debugger", State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}},
		}}},
	}
	client := fake.NewSimpleClientset(pod)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	got, continuation, err := waitForDebugContainer(ctx, client.CoreV1(), "ns", "demo", "debugger")
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "demo" || continuation != "attach" {
		t.Fatalf("got pod=%q continuation=%q, want demo/attach", got.Name, continuation)
	}
}

func TestWaitForDebugContainerReturnsLogsForTerminatedContainer(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "demo", Namespace: "ns"},
		Status: corev1.PodStatus{ContainerStatuses: []corev1.ContainerStatus{{
			Name: "debugger", State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 0}},
		}}},
	}
	client := fake.NewSimpleClientset(pod)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, continuation, err := waitForDebugContainer(ctx, client.CoreV1(), "ns", "demo", "debugger")
	if err != nil {
		t.Fatal(err)
	}
	if continuation != "logs" {
		t.Fatalf("continuation=%q, want logs", continuation)
	}
}
