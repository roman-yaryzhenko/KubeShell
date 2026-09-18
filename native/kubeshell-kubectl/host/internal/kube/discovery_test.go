package kube

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func descriptor(group, version, resource, kind, singular string, shortNames ...string) protocol.ResourceDescriptor {
	return protocol.ResourceDescriptor{
		GVR:          protocol.GVR{Group: group, Version: version, Resource: resource},
		Kind:         kind,
		Namespaced:   true,
		Verbs:        []string{"get", "list", "patch"},
		SingularName: singular,
		ShortNames:   shortNames,
	}
}

func TestSelectResourceDescriptorUsesPreferredVersionWithinOneGroupResource(t *testing.T) {
	alpha := descriptor("apps.example.com", "v1alpha1", "widgets", "Widget", "widget", "wdg")
	stable := descriptor("apps.example.com", "v1", "widgets", "Widget", "widget", "wdg")
	got, err := selectResourceDescriptor(
		protocol.GVR{Group: "apps.example.com", Resource: "widgets"},
		[]protocol.ResourceDescriptor{alpha, stable},
		[]protocol.ResourceDescriptor{stable},
	)
	if err != nil {
		t.Fatalf("resolve preferred version: %v", err)
	}
	if got.GVR.Version != "v1" {
		t.Fatalf("expected preferred v1, got %s", got.GVR.Version)
	}
}

func TestSelectResourceDescriptorCanResolveResourceOnlyInNonPreferredServedVersion(t *testing.T) {
	legacy := descriptor("apps.example.com", "v1alpha1", "legacywidgets", "LegacyWidget", "legacywidget", "lwdg")
	preferredOther := descriptor("apps.example.com", "v1", "widgets", "Widget", "widget", "wdg")
	got, err := selectResourceDescriptor(
		protocol.GVR{Group: "apps.example.com", Resource: "legacywidgets"},
		[]protocol.ResourceDescriptor{legacy, preferredOther},
		[]protocol.ResourceDescriptor{preferredOther},
	)
	if err != nil {
		t.Fatalf("resolve non-preferred-only resource: %v", err)
	}
	if got.GVR != legacy.GVR {
		t.Fatalf("expected %#v, got %#v", legacy.GVR, got.GVR)
	}
}

func TestSelectResourceDescriptorRejectsAmbiguousAliasesAcrossGroupResources(t *testing.T) {
	left := descriptor("one.example.com", "v1", "widgets", "Widget", "widget", "x")
	right := descriptor("two.example.com", "v1", "gadgets", "Gadget", "gadget", "x")
	_, err := selectResourceDescriptor(
		protocol.GVR{Resource: "x"},
		[]protocol.ResourceDescriptor{left, right},
		[]protocol.ResourceDescriptor{left, right},
	)
	if err == nil || !meta.IsAmbiguousError(err) {
		t.Fatalf("expected typed ambiguity, got %v", err)
	}
}

func TestSelectResourceDescriptorReturnsTypedNoMatch(t *testing.T) {
	_, err := selectResourceDescriptor(protocol.GVR{Resource: "missing"}, nil, nil)
	if err == nil || !meta.IsNoMatchError(err) {
		t.Fatalf("expected typed no-match, got %v", err)
	}
}

func TestDescriptorsDropOrphanSubresourcesAndInheritParentGroupVersion(t *testing.T) {
	resources := []metav1.APIResource{
		{Name: "pods/status", Kind: "Pod", Namespaced: true, Verbs: []string{"get"}},
		{Name: "deployments", Kind: "Deployment", Namespaced: true, Verbs: []string{"get", "list"}},
		{Name: "deployments/status", Kind: "Deployment", Namespaced: true, Verbs: []string{"get"}},
	}
	got := descriptorsFromAPIResourceList("apps/v1", resources)
	if len(got) != 1 || got[0].GVR.Resource != "deployments" {
		t.Fatalf("orphan subresource produced topology: %#v", got)
	}
	if len(got[0].Subresources) != 1 {
		t.Fatalf("expected deployment status subresource: %#v", got[0].Subresources)
	}
	sub := got[0].Subresources[0]
	if sub.Group != "apps" || sub.Version != "v1" {
		t.Fatalf("subresource did not inherit parent group/version: %#v", sub)
	}
}

type parityDescriptor struct {
	Group      string   `json:"group"`
	Version    string   `json:"version"`
	Resource   string   `json:"resource"`
	Kind       string   `json:"kind"`
	Singular   string   `json:"singular"`
	ShortNames []string `json:"shortNames"`
	Namespaced bool     `json:"namespaced"`
	Verbs      []string `json:"verbs"`
}

type parityCorpus struct {
	All             []parityDescriptor `json:"all"`
	Preferred       []parityDescriptor `json:"preferred"`
	APIResourceList struct {
		GroupVersion string `json:"groupVersion"`
		Resources    []struct {
			Name         string   `json:"name"`
			SingularName string   `json:"singularName"`
			Kind         string   `json:"kind"`
			Namespaced   bool     `json:"namespaced"`
			Verbs        []string `json:"verbs"`
			ShortNames   []string `json:"shortNames"`
		} `json:"resources"`
	} `json:"apiResourceList"`
}

func loadParityCorpus(t *testing.T) parityCorpus {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve discovery_test.go path")
	}
	path := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "..", "Tests", "Fixtures", "discovery-parity.json"))
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read parity corpus: %v", err)
	}
	var corpus parityCorpus
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatalf("parse parity corpus: %v", err)
	}
	return corpus
}

func parityProtocolDescriptors(items []parityDescriptor) []protocol.ResourceDescriptor {
	out := make([]protocol.ResourceDescriptor, 0, len(items))
	for _, item := range items {
		out = append(out, protocol.ResourceDescriptor{
			GVR:  protocol.GVR{Group: item.Group, Version: item.Version, Resource: item.Resource},
			Kind: item.Kind, Namespaced: item.Namespaced, Verbs: item.Verbs,
			SingularName: item.Singular, ShortNames: item.ShortNames,
		})
	}
	return out
}

func TestFrozenDiscoveryParityCorpus(t *testing.T) {
	corpus := loadParityCorpus(t)
	all := parityProtocolDescriptors(corpus.All)
	preferred := parityProtocolDescriptors(corpus.Preferred)

	got, err := selectResourceDescriptor(protocol.GVR{Group: "apps.example.com", Resource: "widgets"}, all, preferred)
	if err != nil || got.GVR.Version != "v1" {
		t.Fatalf("preferred parity resolution: got=%#v err=%v", got, err)
	}
	got, err = selectResourceDescriptor(protocol.GVR{Group: "apps.example.com", Resource: "legacywidgets"}, all, preferred)
	if err != nil || got.GVR.Version != "v1alpha1" {
		t.Fatalf("non-preferred parity resolution: got=%#v err=%v", got, err)
	}
	if _, err = selectResourceDescriptor(protocol.GVR{Resource: "same"}, all, preferred); err == nil || !meta.IsAmbiguousError(err) {
		t.Fatalf("expected parity ambiguity, got %v", err)
	}

	resources := make([]metav1.APIResource, 0, len(corpus.APIResourceList.Resources))
	for _, item := range corpus.APIResourceList.Resources {
		resources = append(resources, metav1.APIResource{Name: item.Name, SingularName: item.SingularName, Kind: item.Kind, Namespaced: item.Namespaced, Verbs: item.Verbs, ShortNames: item.ShortNames})
	}
	mapped := descriptorsFromAPIResourceList(corpus.APIResourceList.GroupVersion, resources)
	if len(mapped) != 1 || mapped[0].GVR.Resource != "deployments" {
		t.Fatalf("parity corpus orphan subresource produced topology: %#v", mapped)
	}
}
