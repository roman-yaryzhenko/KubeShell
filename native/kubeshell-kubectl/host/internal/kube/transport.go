package kube

import (
	"context"
	"net/http"

	"k8s.io/client-go/rest"
)

// bindRequestContext closes a gap in several kubectl command packages whose public Run methods
// still create REST calls from context.Background(). The transport boundary is the last common
// point before those requests leave the process, so every request is cloned onto the IPC request
// context. This makes managed cancellation authoritative even for embedded kubectl code that does
// not expose context.Context in its public API.
func bindRequestContext(config *rest.Config, ctx context.Context) {
	if ctx == nil {
		return
	}
	config.Wrap(func(next http.RoundTripper) http.RoundTripper {
		return requestContextRoundTripper{next: next, ctx: ctx}
	})
}

type requestContextRoundTripper struct {
	next http.RoundTripper
	ctx  context.Context
}

func (r requestContextRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return r.next.RoundTrip(request.Clone(r.ctx))
}
