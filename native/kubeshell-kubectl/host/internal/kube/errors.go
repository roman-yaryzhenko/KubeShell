package kube

import (
	"context"
	"encoding/json"
	"errors"
	"net"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
)

func wireError(err error, code string) *protocol.WireError {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return &protocol.WireError{Class: "cancelled", Code: "kubectl.cancelled", Message: err.Error()}
	}
	if meta.IsNoMatchError(err) {
		return &protocol.WireError{Class: "invalid", Code: "kubectl.discovery.no-match", Message: err.Error()}
	}
	if meta.IsAmbiguousError(err) {
		return &protocol.WireError{Class: "invalid", Code: "kubectl.discovery.ambiguous-resource", Message: err.Error()}
	}
	result := &protocol.WireError{Class: "transport", Code: code, Message: err.Error()}
	if status, ok := err.(apierrors.APIStatus); ok {
		s := status.Status()
		if data, marshalErr := json.Marshal(s); marshalErr == nil {
			result.Status = data
		}
		result.HTTPStatus = int(s.Code)
		switch {
		case apierrors.IsNotFound(err):
			result.Class = "notfound"
		case apierrors.IsUnauthorized(err):
			result.Class = "authentication"
		case apierrors.IsForbidden(err):
			result.Class = "authorization"
		case apierrors.IsAlreadyExists(err), apierrors.IsConflict(err):
			result.Class = "conflict"
		case apierrors.IsInvalid(err), apierrors.IsBadRequest(err):
			result.Class = "invalid"
		case apierrors.IsMethodNotSupported(err):
			result.Class = "unsupported"
		}
		retry := s.Code == 429 || s.Code >= 500
		result.Retryable = &retry
		return result
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		retry := netErr.Timeout() || netErr.Temporary()
		result.Retryable = &retry
	}
	return result
}

func unsupported(code, message string) *protocol.WireError {
	return &protocol.WireError{Class: "unsupported", Code: code, Message: message}
}

func invalid(code, message string) *protocol.WireError {
	return &protocol.WireError{Class: "invalid", Code: code, Message: message}
}
