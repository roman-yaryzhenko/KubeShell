package protocol

import (
	"encoding/json"
	"testing"
)

func TestDebugRequestPreservesExplicitFalseOptions(t *testing.T) {
	attach := false
	share := false
	keepInit := false
	want := DebugRequest{
		Target: ResourceRef{GVR: GVR{Version: "v1", Resource: "pods"}, Name: "demo", Namespace: NamespaceScope{Kind: "explicit", Name: "ns"}},
		Image:  "ubuntu:24.04", Attach: &attach, ShareProcesses: &share, KeepInitContainers: &keepInit,
	}
	raw, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	var got DebugRequest
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.Attach == nil || *got.Attach || got.ShareProcesses == nil || *got.ShareProcesses || got.KeepInitContainers == nil || *got.KeepInitContainers {
		t.Fatalf("explicit false options did not survive JSON round trip: %#v", got)
	}
}

func TestDebugRequestRoundTripKeepsFutureSurface(t *testing.T) {
	attach := true
	share := false
	keepInit := true
	want := DebugRequest{
		Target: ResourceRef{GVR: GVR{Version: "v1", Resource: "pods"}, Name: "demo", Namespace: NamespaceScope{Kind: "explicit", Name: "ns"}},
		Image:  "example/debug:1", Command: []string{"sh", "-c", "id"}, ArgumentsOnly: true, Attach: &attach,
		Container: "debugger", CopyTo: "demo-copy", Replace: true, Environment: map[string]string{"A": "1"},
		Interactive: true, TTY: true, Quiet: true, KeepLabels: true, KeepAnnotations: true, KeepLiveness: true,
		KeepReadiness: true, KeepStartup: true, KeepInitContainers: &keepInit, SameNode: true,
		SetImages: map[string]string{"app": "example/app:2"}, ShareProcesses: &share, TargetContainer: "app",
		Profile: "future-profile", CustomProfileJSON: `{"securityContext":{"privileged":true}}`, ImagePullPolicy: "IfNotPresent",
	}
	raw, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	var got DebugRequest
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.CopyTo != want.CopyTo || !got.Replace || got.Profile != want.Profile || got.CustomProfileJSON != want.CustomProfileJSON || got.SetImages["app"] != "example/app:2" || got.Environment["A"] != "1" {
		t.Fatalf("future debug surface did not survive JSON round trip: %#v", got)
	}
}
