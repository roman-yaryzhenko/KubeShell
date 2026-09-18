package kube

import (
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestWireErrorMapsAlreadyExistsToConflict(t *testing.T) {
	err := apierrors.NewAlreadyExists(schema.GroupResource{Resource: "configmaps"}, "demo")
	got := wireError(err, "kubectl.create")
	if got == nil {
		t.Fatal("wireError returned nil")
	}
	if got.Class != "conflict" {
		t.Fatalf("class = %q, want conflict", got.Class)
	}
	if got.HTTPStatus != 409 {
		t.Fatalf("http status = %d, want 409", got.HTTPStatus)
	}
}

func TestWireErrorMapsDiscoveryNoMatchAndAmbiguityToInvalid(t *testing.T) {
	noMatch := &meta.NoResourceMatchError{PartialResource: schema.GroupVersionResource{Resource: "missing"}}
	got := wireError(noMatch, "kubectl.discovery")
	if got == nil || got.Class != "invalid" || got.Code != "kubectl.discovery.no-match" {
		t.Fatalf("no-match mapping = %#v", got)
	}

	ambiguous := &meta.AmbiguousResourceError{
		PartialResource: schema.GroupVersionResource{Resource: "x"},
		MatchingResources: []schema.GroupVersionResource{
			{Group: "one.example.com", Version: "v1", Resource: "ones"},
			{Group: "two.example.com", Version: "v1", Resource: "twos"},
		},
	}
	got = wireError(ambiguous, "kubectl.discovery")
	if got == nil || got.Class != "invalid" || got.Code != "kubectl.discovery.ambiguous-resource" {
		t.Fatalf("ambiguity mapping = %#v", got)
	}
}
