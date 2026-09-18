package kube

import (
	"sort"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
)

func configView(s *session) protocol.ConfigViewResponse {
	names := make([]string, 0, len(s.rawConfig.Contexts))
	for name := range s.rawConfig.Contexts {
		names = append(names, name)
	}
	sort.Strings(names)

	contexts := make([]protocol.ConfigContext, 0, len(names))
	for _, name := range names {
		ctx := s.rawConfig.Contexts[name]
		if ctx == nil {
			continue
		}
		contexts = append(contexts, protocol.ConfigContext{
			Name:      name,
			Cluster:   ctx.Cluster,
			User:      ctx.AuthInfo,
			Namespace: ctx.Namespace,
		})
	}
	return protocol.ConfigViewResponse{CurrentContext: s.rawConfig.CurrentContext, Contexts: contexts}
}
