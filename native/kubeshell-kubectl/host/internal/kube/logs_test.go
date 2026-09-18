package kube

import (
	"context"
	"io"
	"strings"
	"testing"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
)

type recordingStream struct {
	items []protocol.StreamItem
	ends  []protocol.StreamEnd
}

func (s *recordingStream) Item(item protocol.StreamItem) error {
	s.items = append(s.items, item)
	return nil
}

func (s *recordingStream) End(end protocol.StreamEnd) error {
	s.ends = append(s.ends, end)
	return nil
}

func TestPumpLogsPreservesFinalPartialLineAndPrefixesRecords(t *testing.T) {
	ops := newOperationManager()
	id := ops.add(7, func() {})
	stream := &recordingStream{}
	reader := io.NopCloser(strings.NewReader("first\r\nsecond"))

	pumpLogs(context.Background(), id, "pod-a", "api", true, reader, ops, stream)

	if len(stream.items) != 2 {
		t.Fatalf("got %d stream items, want 2: %#v", len(stream.items), stream.items)
	}
	if stream.items[0].Text != "pod-a/api first" || stream.items[1].Text != "pod-a/api second" {
		t.Fatalf("unexpected log records: %#v", stream.items)
	}
	if len(stream.ends) != 1 || stream.ends[0].OperationID != id {
		t.Fatalf("unexpected stream end: %#v", stream.ends)
	}

	ops.mu.Lock()
	_, stillRunning := ops.operations[id]
	ops.mu.Unlock()
	if stillRunning {
		t.Fatal("pumpLogs must release its operation handle")
	}
}
