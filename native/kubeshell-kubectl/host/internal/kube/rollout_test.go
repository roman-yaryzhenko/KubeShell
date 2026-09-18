package kube

import (
	"testing"

	cmdutil "k8s.io/kubectl/pkg/cmd/util"
)

func TestRollbackDryRun(t *testing.T) {
	tests := []struct {
		input string
		want  cmdutil.DryRunStrategy
	}{
		{"", cmdutil.DryRunNone},
		{"none", cmdutil.DryRunNone},
		{"client", cmdutil.DryRunClient},
		{"server", cmdutil.DryRunServer},
		{"CLIENT", cmdutil.DryRunClient},
	}
	for _, tt := range tests {
		got, err := rollbackDryRun(tt.input)
		if err != nil {
			t.Fatalf("rollbackDryRun(%q): %v", tt.input, err)
		}
		if got != tt.want {
			t.Fatalf("rollbackDryRun(%q)=%v, want %v", tt.input, got, tt.want)
		}
	}
	if _, err := rollbackDryRun("future"); err == nil {
		t.Fatal("expected unknown dry-run value to fail")
	}
}
