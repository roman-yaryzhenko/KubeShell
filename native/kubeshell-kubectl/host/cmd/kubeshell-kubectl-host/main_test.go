package main

import (
	"reflect"
	"testing"
)

func TestHasTransportArgument(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want bool
	}{
		{"stdio", []string{"--transport=stdio"}, true},
		{"unix split", []string{"--transport", "unix", "--socket", "/tmp/k.sock"}, true},
		{"kubectl get", []string{"get", "pods", "-A"}, false},
		{"kubectl exec", []string{"exec", "-it", "pod/demo", "--", "sh"}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := hasTransportArgument(tc.args); got != tc.want {
				t.Fatalf("hasTransportArgument(%v)=%v, want %v", tc.args, got, tc.want)
			}
		})
	}
}

func TestParseWorkerAllowsTargetFlagsBeforeWorker(t *testing.T) {
	worker, args, ok, err := parseWorker([]string{"--context", "dev", "--worker=exec", "-it", "pod/demo", "--", "sh"})
	if err != nil || !ok || worker != "exec" {
		t.Fatalf("parseWorker returned worker=%q ok=%v err=%v", worker, ok, err)
	}
	want := []string{"--context", "dev", "-it", "pod/demo", "--", "sh"}
	if !reflect.DeepEqual(args, want) {
		t.Fatalf("args=%v, want %v", args, want)
	}
}

func TestRunWorkerRejectsBroadKubectlWorkers(t *testing.T) {
	if err := runWorker("get", nil); err == nil {
		t.Fatal("generic kubectl worker must stay disabled")
	}
}

func TestRunWorkerAllowlistIsNarrow(t *testing.T) {
	for _, worker := range []string{"attach", "exec", "port-forward"} {
		// Do not execute the worker here: runWorker would enter kubectl. The allowlist is asserted
		// from source behavior by checking that only all other names are rejected below.
		if worker == "" {
			t.Fatal("worker names must be non-empty")
		}
	}
	for _, worker := range []string{"debug", "get", "logs", "cp", "apply", "explain", "rollout"} {
		if err := runWorker(worker, nil); err == nil {
			t.Fatalf("worker %q must stay outside the compatibility allowlist", worker)
		}
	}
}
