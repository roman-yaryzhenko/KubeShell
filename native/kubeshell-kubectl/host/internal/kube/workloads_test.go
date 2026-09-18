package kube

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
)

func TestSetContainerImageTargetsNamedContainer(t *testing.T) {
	containers := []corev1.Container{{Name: "api", Image: "old-api"}, {Name: "sidecar", Image: "old-sidecar"}}
	if !setContainerImage(containers, "api", "new-api") {
		t.Fatal("expected named container to be matched")
	}
	if containers[0].Image != "new-api" || containers[1].Image != "old-sidecar" {
		t.Fatalf("unexpected images: %#v", containers)
	}
	if setContainerImage(containers, "missing", "ignored") {
		t.Fatal("missing container must not report a match")
	}
}

func TestSetContainerImageWildcardTargetsEveryContainer(t *testing.T) {
	containers := []corev1.Container{{Name: "api", Image: "old-api"}, {Name: "sidecar", Image: "old-sidecar"}}
	if !setContainerImage(containers, "*", "shared") {
		t.Fatal("wildcard should match all containers")
	}
	for _, container := range containers {
		if container.Image != "shared" {
			t.Fatalf("container %q was not updated: %#v", container.Name, containers)
		}
	}
}
