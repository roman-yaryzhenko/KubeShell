package kube

import (
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// requestClientGetter is the deliberately small adapter expected by cli-runtime/kubectl.
// A new instance is created per apply operation so mutable kubectl option objects never
// become session state.
type requestClientGetter struct {
	config    *rest.Config
	raw       clientcmd.ClientConfig
	discovery discovery.CachedDiscoveryInterface
	mapper    meta.RESTMapper
}

func (g *requestClientGetter) ToRESTConfig() (*rest.Config, error) {
	return rest.CopyConfig(g.config), nil
}
func (g *requestClientGetter) ToDiscoveryClient() (discovery.CachedDiscoveryInterface, error) {
	return g.discovery, nil
}
func (g *requestClientGetter) ToRESTMapper() (meta.RESTMapper, error)        { return g.mapper, nil }
func (g *requestClientGetter) ToRawKubeConfigLoader() clientcmd.ClientConfig { return g.raw }
