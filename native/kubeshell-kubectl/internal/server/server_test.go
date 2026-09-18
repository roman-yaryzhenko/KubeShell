package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
)

type fakeHandler struct {
	mu        sync.Mutex
	cancelled []uint64
	closed    atomic.Int32
}

func (f *fakeHandler) HelloAck() protocol.HelloAck {
	return protocol.HelloAck{FeatureBits: protocol.FeatureCRUD}
}
func (f *fakeHandler) Handle(_ context.Context, req protocol.Request, _ StreamWriter) (any, *protocol.WireError) {
	return map[string]any{"method": req.Method}, nil
}
func (f *fakeHandler) CancelOperation(id uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancelled = append(f.cancelled, id)
}
func (f *fakeHandler) Close() error { f.closed.Add(1); return nil }

func writeHello(t *testing.T, input *bytes.Buffer, correlation uint64) {
	t.Helper()
	hello, _ := json.Marshal(protocol.Hello{MinProtocol: 1, MaxProtocol: 1, ContractHash: protocol.ContractHash})
	if err := protocol.WriteFrame(input, protocol.Frame{Kind: protocol.KindHello, CorrelationID: correlation, Payload: hello}); err != nil {
		t.Fatal(err)
	}
}

func TestHandshakeAndRequest(t *testing.T) {
	var input bytes.Buffer
	writeHello(t, &input, 1)
	reqBody, _ := json.Marshal(protocol.Request{Method: protocol.MethodGet})
	if err := protocol.WriteFrame(&input, protocol.Frame{Kind: protocol.KindRequest, CorrelationID: 2, Payload: reqBody}); err != nil {
		t.Fatal(err)
	}
	if err := protocol.WriteFrame(&input, protocol.Frame{Kind: protocol.KindShutdown, CorrelationID: 3}); err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	handler := &fakeHandler{}
	srv := New(&input, &output, handler)
	if err := srv.Serve(context.Background()); err != nil {
		t.Fatal(err)
	}

	ack, err := protocol.ReadFrame(&output)
	if err != nil {
		t.Fatal(err)
	}
	if ack.Kind != protocol.KindHelloAck {
		t.Fatalf("expected hello ack, got %d", ack.Kind)
	}
	response, err := protocol.ReadFrame(&output)
	if err != nil {
		t.Fatal(err)
	}
	if response.Kind != protocol.KindResponse || response.CorrelationID != 2 {
		t.Fatalf("unexpected response %#v", response)
	}
	if handler.closed.Load() != 1 {
		t.Fatalf("handler close count = %d, want 1", handler.closed.Load())
	}
}

type blockingHandler struct {
	fakeHandler
	started   chan struct{}
	cancelled atomic.Bool
}

func (h *blockingHandler) Handle(ctx context.Context, _ protocol.Request, _ StreamWriter) (any, *protocol.WireError) {
	select {
	case <-h.started:
	default:
		close(h.started)
	}
	<-ctx.Done()
	h.cancelled.Store(true)
	return nil, &protocol.WireError{Class: "cancelled", Code: "test.cancelled", Message: ctx.Err().Error()}
}

func TestCorrelationCancellationStopsRequest(t *testing.T) {
	client, serverSide := netPipe(t)
	defer client.Close()
	defer serverSide.Close()

	handler := &blockingHandler{started: make(chan struct{})}
	srv := New(serverSide, serverSide, handler)
	done := make(chan error, 1)
	go func() { done <- srv.Serve(context.Background()) }()

	hello, _ := json.Marshal(protocol.Hello{MinProtocol: 1, MaxProtocol: 1, ContractHash: protocol.ContractHash})
	if err := protocol.WriteFrame(client, protocol.Frame{Kind: protocol.KindHello, CorrelationID: 1, Payload: hello}); err != nil {
		t.Fatal(err)
	}
	if _, err := protocol.ReadFrame(client); err != nil {
		t.Fatal(err)
	}

	req, _ := json.Marshal(protocol.Request{Method: protocol.MethodGet})
	if err := protocol.WriteFrame(client, protocol.Frame{Kind: protocol.KindRequest, CorrelationID: 41, Payload: req}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-handler.started:
	case <-time.After(time.Second):
		t.Fatal("handler did not start")
	}
	cancel, _ := json.Marshal(protocol.Cancel{CorrelationID: 41})
	if err := protocol.WriteFrame(client, protocol.Frame{Kind: protocol.KindCancel, CorrelationID: 42, Payload: cancel}); err != nil {
		t.Fatal(err)
	}
	frame, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Kind != protocol.KindError || frame.CorrelationID != 41 {
		t.Fatalf("unexpected cancellation response %#v", frame)
	}
	if !handler.cancelled.Load() {
		t.Fatal("request context was not cancelled")
	}
	if err := protocol.WriteFrame(client, protocol.Frame{Kind: protocol.KindShutdown, CorrelationID: 43}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not shut down")
	}
}

func TestOperationCancellationIsIndependent(t *testing.T) {
	var input bytes.Buffer
	writeHello(t, &input, 1)
	cancel, _ := json.Marshal(protocol.Cancel{OperationID: 77})
	if err := protocol.WriteFrame(&input, protocol.Frame{Kind: protocol.KindCancel, CorrelationID: 2, Payload: cancel}); err != nil {
		t.Fatal(err)
	}
	if err := protocol.WriteFrame(&input, protocol.Frame{Kind: protocol.KindShutdown, CorrelationID: 3}); err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	handler := &fakeHandler{}
	if err := New(&input, &output, handler).Serve(context.Background()); err != nil {
		t.Fatal(err)
	}
	handler.mu.Lock()
	defer handler.mu.Unlock()
	if len(handler.cancelled) != 1 || handler.cancelled[0] != 77 {
		t.Fatalf("operation cancellations = %#v, want [77]", handler.cancelled)
	}
}

// net.Pipe keeps the cancellation test deterministic while still exercising concurrent reader/writer behavior.
func netPipe(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	return net.Pipe()
}

type streamingHandler struct{ fakeHandler }

func (h *streamingHandler) Handle(_ context.Context, _ protocol.Request, stream StreamWriter) (any, *protocol.WireError) {
	if err := stream.Item(protocol.StreamItem{OperationID: 88, EventType: "added", ResourceVersion: "123"}); err != nil {
		return nil, &protocol.WireError{Class: "internal", Code: "test.stream-item", Message: err.Error()}
	}
	if err := stream.End(protocol.StreamEnd{OperationID: 88}); err != nil {
		return nil, &protocol.WireError{Class: "internal", Code: "test.stream-end", Message: err.Error()}
	}
	return map[string]any{"operationId": 88}, nil
}

func TestStreamFramesUseRequestCorrelationAndPrecedeResponse(t *testing.T) {
	var input bytes.Buffer
	writeHello(t, &input, 1)
	reqBody, _ := json.Marshal(protocol.Request{Method: protocol.MethodWatchStart})
	if err := protocol.WriteFrame(&input, protocol.Frame{Kind: protocol.KindRequest, CorrelationID: 55, Payload: reqBody}); err != nil {
		t.Fatal(err)
	}
	if err := protocol.WriteFrame(&input, protocol.Frame{Kind: protocol.KindShutdown, CorrelationID: 56}); err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	if err := New(&input, &output, &streamingHandler{}).Serve(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := protocol.ReadFrame(&output); err != nil { // hello ack
		t.Fatal(err)
	}
	for _, wantKind := range []protocol.MessageKind{protocol.KindStreamItem, protocol.KindStreamEnd, protocol.KindResponse} {
		frame, err := protocol.ReadFrame(&output)
		if err != nil {
			t.Fatal(err)
		}
		if frame.Kind != wantKind || frame.CorrelationID != 55 {
			t.Fatalf("frame = kind %d correlation %d, want kind %d correlation 55", frame.Kind, frame.CorrelationID, wantKind)
		}
	}
}
