package kube

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	ipcserver "github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/server"
)

const (
	BuildVersion    = "0.3.0-alpha11"
	KubectlVersion  = "v1.37.0"
	ClientGoVersion = "v0.37.0"
)

type Handler struct {
	sessions   *sessionManager
	operations *operationManager
}

func NewHandler() *Handler {
	return &Handler{sessions: newSessionManager(), operations: newOperationManager()}
}

func (h *Handler) HelloAck() protocol.HelloAck {
	return protocol.HelloAck{
		FeatureBits: protocol.FeatureDiscovery | protocol.FeatureCRUD | protocol.FeatureClientPreview |
			protocol.FeatureServerPreview | protocol.FeatureClientSideApply | protocol.FeatureServerSideApply |
			protocol.FeatureWatch | protocol.FeatureSubresources | protocol.FeatureImpersonation | protocol.FeatureFieldValidation |
			protocol.FeatureSchema | protocol.FeatureRolloutUndo | protocol.FeatureWorkloads | protocol.FeatureDiagnostics | protocol.FeatureLogs | protocol.FeatureCopy | protocol.FeatureDebug,
		BuildVersion:    BuildVersion,
		KubectlVersion:  KubectlVersion,
		ClientGoVersion: ClientGoVersion,
	}
}

func (h *Handler) Handle(ctx context.Context, request protocol.Request, stream ipcserver.StreamWriter) (any, *protocol.WireError) {
	switch request.Method {
	case protocol.MethodSessionCreate:
		var body protocol.SessionCreateRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("session.request", err.Error())
		}
		session, err := h.sessions.create(body)
		if err != nil {
			return nil, &protocol.WireError{Class: "configuration", Code: "session.create", Message: err.Error()}
		}
		return protocol.SessionCreateResponse{SessionID: session.id}, nil
	case protocol.MethodSessionClose:
		var body protocol.SessionCloseRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("session.request", err.Error())
		}
		h.operations.cancelSession(body.SessionID)
		h.sessions.close(body.SessionID)
		return struct{}{}, nil
	}

	session, ok := h.sessions.get(request.SessionID)
	if !ok {
		return nil, &protocol.WireError{Class: "configuration", Code: "session.not-found", Message: fmt.Sprintf("session %d does not exist", request.SessionID)}
	}

	switch request.Method {
	case protocol.MethodDiscoverAPIVersion:
		var body protocol.DiscoverRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("discovery.request", err.Error())
		}
		result, err := discoverAPIVersion(ctx, session, body)
		if err != nil {
			return nil, wireError(err, "discovery.api-version")
		}
		return result, nil
	case protocol.MethodDiscoverPreferred:
		var body protocol.DiscoverRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("discovery.request", err.Error())
		}
		result, err := discoverPreferred(ctx, session, body)
		if err != nil {
			return nil, wireError(err, "discovery.preferred")
		}
		return result, nil
	case protocol.MethodResolveResource:
		var body protocol.DiscoverRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("discovery.request", err.Error())
		}
		result, err := resolveResource(ctx, session, body)
		if err != nil {
			return nil, wireError(err, "discovery.resolve")
		}
		return result, nil
	case protocol.MethodWatchStart:
		var body protocol.OperationRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("operation.request", err.Error())
		}
		return startWatch(ctx, h.operations, request.SessionID, session, body, stream)
	case protocol.MethodLogsStart:
		var body protocol.LogRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("logs.request", err.Error())
		}
		return startLogs(ctx, h.operations, request.SessionID, session, body, stream)
	case protocol.MethodConfigView:
		return configView(session), nil
	case protocol.MethodAccessReview:
		var body protocol.AccessReviewRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("diagnostics.access.request", err.Error())
		}
		return reviewAccess(ctx, session, body)
	case protocol.MethodPodMetrics, protocol.MethodNodeMetrics:
		var body protocol.MetricsRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("diagnostics.metrics.request", err.Error())
		}
		return metrics(ctx, session, body, request.Method == protocol.MethodPodMetrics)
	case protocol.MethodDNSProbe:
		var body protocol.DNSProbeRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("diagnostics.dns.request", err.Error())
		}
		return probeDNS(ctx, session, body)
	case protocol.MethodCopy:
		var body protocol.CopyRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("copy.request", err.Error())
		}
		return copyFiles(ctx, session, body)
	case protocol.MethodDebug:
		var body protocol.DebugRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("debug.request", err.Error())
		}
		return debugResource(ctx, session, body)
	case protocol.MethodExplain:
		var body protocol.SchemaRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("schema.request", err.Error())
		}
		result, err := explainSchema(ctx, session, body)
		if err != nil {
			return nil, wireError(err, "schema.explain")
		}
		return result, nil
	case protocol.MethodRolloutUndo, protocol.MethodRolloutRestart, protocol.MethodScale, protocol.MethodSetImage, protocol.MethodRolloutStatus:
		var body protocol.OperationRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("operation.request", err.Error())
		}
		switch request.Method {
		case protocol.MethodRolloutUndo:
			return rolloutUndo(ctx, session, body)
		case protocol.MethodRolloutRestart:
			return rolloutRestart(ctx, session, body)
		case protocol.MethodScale:
			return scaleResource(ctx, session, body)
		case protocol.MethodSetImage:
			return setImage(ctx, session, body)
		default:
			return rolloutStatus(ctx, session, body)
		}
	case protocol.MethodGet, protocol.MethodList, protocol.MethodCreate, protocol.MethodReplace, protocol.MethodDelete, protocol.MethodPatch, protocol.MethodApply:
		var body protocol.OperationRequest
		if err := decodeBody(request.Body, &body); err != nil {
			return nil, invalid("operation.request", err.Error())
		}
		return executeOperation(ctx, session, request.Method, body)
	default:
		return nil, unsupported("protocol.method", fmt.Sprintf("method %d is not supported", request.Method))
	}
}

func (h *Handler) CancelOperation(id uint64) { h.operations.cancel(id) }
func (h *Handler) Close() error              { h.operations.closeAll(); h.sessions.closeAll(); return nil }

func decodeBody(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return fmt.Errorf("request body is required")
	}
	return json.Unmarshal(raw, target)
}
