package kube

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	ipcserver "github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/server"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
)

type operationManager struct {
	next       atomic.Uint64
	mu         sync.Mutex
	operations map[uint64]*runningOperation
}

type runningOperation struct {
	sessionID uint64
	cancel    context.CancelFunc
}

func newOperationManager() *operationManager {
	return &operationManager{operations: make(map[uint64]*runningOperation)}
}

func (m *operationManager) add(sessionID uint64, cancel context.CancelFunc) uint64 {
	id := m.next.Add(1)
	m.mu.Lock()
	m.operations[id] = &runningOperation{sessionID: sessionID, cancel: cancel}
	m.mu.Unlock()
	return id
}
func (m *operationManager) done(id uint64) { m.mu.Lock(); delete(m.operations, id); m.mu.Unlock() }
func (m *operationManager) cancel(id uint64) {
	m.mu.Lock()
	op := m.operations[id]
	m.mu.Unlock()
	if op != nil {
		op.cancel()
	}
}
func (m *operationManager) cancelSession(sessionID uint64) {
	m.mu.Lock()
	cancels := make([]context.CancelFunc, 0)
	for _, op := range m.operations {
		if op.sessionID == sessionID {
			cancels = append(cancels, op.cancel)
		}
	}
	m.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}
func (m *operationManager) closeAll() {
	m.mu.Lock()
	cancels := make([]context.CancelFunc, 0, len(m.operations))
	for _, op := range m.operations {
		cancels = append(cancels, op.cancel)
	}
	m.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

func startWatch(ctx context.Context, ops *operationManager, sessionID uint64, s *session, req protocol.OperationRequest, stream ipcserver.StreamWriter) (protocol.OperationResponse, *protocol.WireError) {
	if req.Query == nil {
		return protocol.OperationResponse{}, invalid("kubectl.query-required", "watch requires a resource query")
	}
	if req.Query.Subresource != "" {
		return protocol.OperationResponse{}, unsupported("kubectl.watch-subresource", "generic subresource watch is not supported by the dynamic client")
	}
	target, iface, _, warnings, err := interfaceForQuery(ctx, s, req.Execution, *req.Query)
	if err != nil {
		return protocol.OperationResponse{}, wireError(err, "kubectl.watch.prepare")
	}

	watchCtx, cancel := context.WithCancel(ctx)
	options := metav1.ListOptions{
		LabelSelector:       req.Query.LabelSelector,
		FieldSelector:       req.Query.FieldSelector,
		ResourceVersion:     req.ResourceVersion,
		AllowWatchBookmarks: req.AllowBookmarks,
		Watch:               true,
	}
	watcher, err := iface.Watch(watchCtx, options)
	if err != nil {
		cancel()
		return protocol.OperationResponse{}, wireError(err, "kubectl.watch")
	}
	id := ops.add(sessionID, cancel)
	go pumpWatch(watchCtx, id, target, watcher, ops, stream)
	return protocol.OperationResponse{OperationID: id, Warnings: warnings.snapshot()}, nil
}

func pumpWatch(ctx context.Context, id uint64, target resolvedResource, watcher watch.Interface, ops *operationManager, stream ipcserver.StreamWriter) {
	defer ops.done(id)
	defer watcher.Stop()
	defer func() { _ = stream.End(protocol.StreamEnd{OperationID: id}) }()

	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-watcher.ResultChan():
			if !ok {
				return
			}
			item := protocol.StreamItem{OperationID: id, EventType: strings.ToLower(string(event.Type))}
			if event.Type == watch.Error {
				err := apierrors.FromObject(event.Object)
				item.Error = wireError(err, "kubectl.watch.event")
				_ = stream.Item(item)
				continue
			}
			raw, err := json.Marshal(event.Object)
			if err != nil {
				item.Error = wireError(err, "kubectl.watch.serialize")
				_ = stream.Item(item)
				continue
			}
			item.Resource = &protocol.ResourceResult{GVR: wireGVR(target.gvr), JSON: raw}
			if accessor, err := meta.Accessor(event.Object); err == nil {
				item.ResourceVersion = accessor.GetResourceVersion()
			}
			if err := stream.Item(item); err != nil {
				return
			}
		}
	}
}
