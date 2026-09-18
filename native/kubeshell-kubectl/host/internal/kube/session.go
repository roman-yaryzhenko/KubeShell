package kube

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/openapi"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

type sessionManager struct {
	next     atomic.Uint64
	mu       sync.RWMutex
	sessions map[uint64]*session
}

type session struct {
	id                       uint64
	rawConfig                clientcmdapi.Config
	loadingRules             *clientcmd.ClientConfigLoadingRules
	contextName              string
	explicitDefaultNamespace string
	baseConfig               *rest.Config
	kubeconfigNamespace      string

	discoveryMu sync.Mutex
	discovery   map[string]*discoveryBundle
}

type discoveryBundle struct {
	client  discovery.CachedDiscoveryInterfaceWithContext
	mapper  meta.RESTMapperWithContext
	openAPI openapi.ClientWithContext
}

func newSessionManager() *sessionManager { return &sessionManager{sessions: make(map[uint64]*session)} }

func (m *sessionManager) create(req protocol.SessionCreateRequest) (*session, error) {
	if len(req.KubeconfigPaths) == 0 {
		return nil, fmt.Errorf("no kubeconfig paths were supplied; the native host does not inspect ambient KUBECONFIG or the home-directory default")
	}

	rules := &clientcmd.ClientConfigLoadingRules{
		Precedence:        append([]string(nil), req.KubeconfigPaths...),
		DoNotResolvePaths: false,
		WarnIfAllMissing:  true,
	}
	raw, err := rules.Load()
	if err != nil {
		return nil, err
	}
	overrides := &clientcmd.ConfigOverrides{CurrentContext: req.Context}
	if req.DefaultNamespace != "" {
		overrides.Context.Namespace = req.DefaultNamespace
	}
	clientConfig := clientcmd.NewNonInteractiveClientConfig(*raw, req.Context, overrides, rules)
	base, err := clientConfig.ClientConfig()
	if err != nil {
		return nil, err
	}
	ns, _, err := clientConfig.Namespace()
	if err != nil {
		return nil, err
	}

	id := m.next.Add(1)
	s := &session{
		id:                       id,
		rawConfig:                *raw,
		loadingRules:             rules,
		contextName:              req.Context,
		explicitDefaultNamespace: req.DefaultNamespace,
		baseConfig:               base,
		kubeconfigNamespace:      ns,
		discovery:                make(map[string]*discoveryBundle),
	}
	m.mu.Lock()
	m.sessions[id] = s
	m.mu.Unlock()
	return s, nil
}

func (m *sessionManager) get(id uint64) (*session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

func (m *sessionManager) close(id uint64) {
	m.mu.Lock()
	delete(m.sessions, id)
	m.mu.Unlock()
}

func (m *sessionManager) closeAll() {
	m.mu.Lock()
	m.sessions = make(map[uint64]*session)
	m.mu.Unlock()
}

func (s *session) defaultNamespace() string {
	if s.explicitDefaultNamespace != "" {
		return s.explicitDefaultNamespace
	}
	if s.kubeconfigNamespace != "" {
		return s.kubeconfigNamespace
	}
	return "default"
}

func (s *session) configFor(exec protocol.ExecutionContext) *rest.Config {
	cfg := rest.CopyConfig(s.baseConfig)
	if exec.TimeoutMilliseconds > 0 {
		cfg.Timeout = time.Duration(exec.TimeoutMilliseconds) * time.Millisecond
	}
	if exec.UserAgent != "" {
		cfg.UserAgent = exec.UserAgent
	}
	if exec.Impersonation != nil {
		cfg.Impersonate = rest.ImpersonationConfig{
			UserName: exec.Impersonation.User,
			UID:      exec.Impersonation.UID,
			Groups:   append([]string(nil), exec.Impersonation.Groups...),
			Extra:    cloneExtra(exec.Impersonation.Extra),
		}
	}
	return cfg
}

func cloneExtra(input map[string][]string) map[string][]string {
	if len(input) == 0 {
		return nil
	}
	out := make(map[string][]string, len(input))
	for k, v := range input {
		out[k] = append([]string(nil), v...)
	}
	return out
}

func (s *session) clientConfigFor(namespace string, enforce bool) clientcmd.ClientConfig {
	overrides := &clientcmd.ConfigOverrides{CurrentContext: s.contextName}
	if enforce {
		overrides.Context.Namespace = namespace
	} else if s.explicitDefaultNamespace != "" {
		overrides.Context.Namespace = s.explicitDefaultNamespace
	}
	// RawConfig was loaded once at session creation. Reconstructing this small loader prevents
	// kubectl apply from consulting ambient configuration while still allowing per-operation namespace overrides.
	return clientcmd.NewNonInteractiveClientConfig(s.rawConfig, s.contextName, overrides, s.loadingRules)
}

func (s *session) bundle(exec protocol.ExecutionContext, refresh bool) (*discoveryBundle, error) {
	// Discovery clients retain the rest.Config used to create them. Include every
	// per-call field that changes transport behavior so a cached client never inherits
	// a timeout, user-agent, or impersonation identity from an unrelated operation.
	keyBytes, _ := json.Marshal(struct {
		TimeoutMilliseconds int64                   `json:"timeoutMilliseconds,omitempty"`
		UserAgent           string                  `json:"userAgent,omitempty"`
		Impersonation       *protocol.Impersonation `json:"impersonation,omitempty"`
	}{exec.TimeoutMilliseconds, exec.UserAgent, exec.Impersonation})
	key := string(keyBytes)

	s.discoveryMu.Lock()
	defer s.discoveryMu.Unlock()
	if refresh {
		delete(s.discovery, key)
	}
	if existing := s.discovery[key]; existing != nil {
		return existing, nil
	}

	client, err := discovery.NewDiscoveryClientForConfig(s.configFor(exec))
	if err != nil {
		return nil, err
	}
	contextualClient := discovery.ToDiscoveryInterfaceWithContext(client)
	cached := memory.NewMemCacheClientWithContext(contextualClient)
	deferred := restmapper.NewDeferredDiscoveryRESTMapperWithContext(cached)
	mapper := restmapper.NewShortcutExpanderWithContext(deferred, contextualClient, nil)
	bundle := &discoveryBundle{client: cached, mapper: mapper, openAPI: cached.OpenAPIV3WithContext(context.Background())}
	s.discovery[key] = bundle
	return bundle, nil
}
