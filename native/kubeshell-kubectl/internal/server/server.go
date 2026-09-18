package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
)

type Handler interface {
	HelloAck() protocol.HelloAck
	Handle(context.Context, protocol.Request, StreamWriter) (any, *protocol.WireError)
	CancelOperation(uint64)
	Close() error
}

type StreamWriter interface {
	Item(protocol.StreamItem) error
	End(protocol.StreamEnd) error
}

type Server struct {
	reader  io.Reader
	writer  io.Writer
	handler Handler

	writeMu    sync.Mutex
	inflightMu sync.Mutex
	inflight   map[uint64]context.CancelFunc
	closeOnce  sync.Once
	requestWG  sync.WaitGroup
}

func New(reader io.Reader, writer io.Writer, handler Handler) *Server {
	return &Server{reader: reader, writer: writer, handler: handler, inflight: make(map[uint64]context.CancelFunc)}
}

func (s *Server) Serve(ctx context.Context) error {
	if err := s.handshake(); err != nil {
		return err
	}
	defer func() {
		// Every request context is owned by the server rather than by the transport reader.
		// Cancelling and joining here prevents request goroutines from outliving a broken IPC
		// connection; long-lived watch operations are cancelled by Handler.Close as well.
		s.cancelAll()
		s.requestWG.Wait()
		s.closeHandler()
	}()

	for {
		frame, err := protocol.ReadFrame(s.reader)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return nil
			}
			return err
		}
		switch frame.Kind {
		case protocol.KindRequest:
			var req protocol.Request
			if err := json.Unmarshal(frame.Payload, &req); err != nil {
				_ = s.writeError(frame.CorrelationID, &protocol.WireError{Class: "protocol", Code: "protocol.invalid-request", Message: err.Error()})
				continue
			}
			// Do not register every request as a child of the process-lifetime context: a
			// successful watch deliberately survives the short request that created it.
			// Server shutdown still reaches in-flight requests through cancelAll(), while
			// operationManager owns cancellation after WatchStart returns.
			requestCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
			s.setInflight(frame.CorrelationID, cancel)
			s.requestWG.Add(1)
			go func() {
				defer s.requestWG.Done()
				s.handleRequest(requestCtx, frame.CorrelationID, req)
			}()
		case protocol.KindCancel:
			var cancel protocol.Cancel
			if err := json.Unmarshal(frame.Payload, &cancel); err != nil {
				_ = s.writeError(frame.CorrelationID, &protocol.WireError{Class: "protocol", Code: "protocol.invalid-cancel", Message: err.Error()})
				continue
			}
			if cancel.CorrelationID != 0 {
				s.cancelCorrelation(cancel.CorrelationID)
			}
			if cancel.OperationID != 0 {
				s.handler.CancelOperation(cancel.OperationID)
			}
		case protocol.KindPing:
			if err := s.write(protocol.Frame{Kind: protocol.KindPong, CorrelationID: frame.CorrelationID}); err != nil {
				return err
			}
		case protocol.KindShutdown:
			return nil
		default:
			if err := s.writeError(frame.CorrelationID, &protocol.WireError{Class: "protocol", Code: "protocol.unexpected-frame", Message: fmt.Sprintf("unexpected frame kind %d", frame.Kind)}); err != nil {
				return err
			}
		}
	}
}

func (s *Server) handshake() error {
	frame, err := protocol.ReadFrame(s.reader)
	if err != nil {
		return err
	}
	if frame.Kind != protocol.KindHello {
		return fmt.Errorf("first frame must be hello, got %d", frame.Kind)
	}
	var hello protocol.Hello
	if err := json.Unmarshal(frame.Payload, &hello); err != nil {
		return err
	}
	if hello.MinProtocol > uint16(protocol.ProtocolMajor) || hello.MaxProtocol < uint16(protocol.ProtocolMajor) {
		_ = s.writeError(frame.CorrelationID, &protocol.WireError{Class: "protocol", Code: "protocol.no-common-version", Message: "no mutually supported protocol version"})
		return errors.New("no mutually supported protocol version")
	}
	if hello.ContractHash != protocol.ContractHash {
		_ = s.writeError(frame.CorrelationID, &protocol.WireError{Class: "protocol", Code: "protocol.contract-hash", Message: "wire contract fingerprint mismatch"})
		return errors.New("wire contract fingerprint mismatch")
	}
	ack := s.handler.HelloAck()
	ack.Protocol = protocol.ProtocolMajor
	ack.ContractHash = protocol.ContractHash
	payload, err := json.Marshal(ack)
	if err != nil {
		return err
	}
	return s.write(protocol.Frame{Kind: protocol.KindHelloAck, CorrelationID: frame.CorrelationID, Payload: payload})
}

func (s *Server) handleRequest(ctx context.Context, correlationID uint64, req protocol.Request) {
	defer s.clearInflight(correlationID)
	response, wireErr := s.handler.Handle(ctx, req, streamWriter{server: s, correlationID: correlationID})
	if wireErr != nil {
		_ = s.writeError(correlationID, wireErr)
		return
	}
	body, err := json.Marshal(response)
	if err != nil {
		_ = s.writeError(correlationID, &protocol.WireError{Class: "internal", Code: "host.response-serialization", Message: err.Error()})
		return
	}
	envelope, err := json.Marshal(protocol.Response{Body: body})
	if err != nil {
		_ = s.writeError(correlationID, &protocol.WireError{Class: "internal", Code: "host.response-envelope", Message: err.Error()})
		return
	}
	_ = s.write(protocol.Frame{Kind: protocol.KindResponse, CorrelationID: correlationID, Payload: envelope})
}

func (s *Server) writeError(correlationID uint64, wireErr *protocol.WireError) error {
	payload, err := json.Marshal(wireErr)
	if err != nil {
		return err
	}
	return s.write(protocol.Frame{Kind: protocol.KindError, CorrelationID: correlationID, Payload: payload})
}

func (s *Server) write(frame protocol.Frame) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return protocol.WriteFrame(s.writer, frame)
}

func (s *Server) setInflight(id uint64, cancel context.CancelFunc) {
	s.inflightMu.Lock()
	defer s.inflightMu.Unlock()
	if previous := s.inflight[id]; previous != nil {
		previous()
	}
	s.inflight[id] = cancel
}

func (s *Server) clearInflight(id uint64) {
	s.inflightMu.Lock()
	defer s.inflightMu.Unlock()
	delete(s.inflight, id)
}

func (s *Server) cancelCorrelation(id uint64) {
	s.inflightMu.Lock()
	cancel := s.inflight[id]
	s.inflightMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *Server) cancelAll() {
	s.inflightMu.Lock()
	cancels := make([]context.CancelFunc, 0, len(s.inflight))
	for _, cancel := range s.inflight {
		cancels = append(cancels, cancel)
	}
	s.inflightMu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

func (s *Server) closeHandler() { s.closeOnce.Do(func() { _ = s.handler.Close() }) }

type streamWriter struct {
	server        *Server
	correlationID uint64
}

func (w streamWriter) Item(item protocol.StreamItem) error {
	payload, err := json.Marshal(item)
	if err != nil {
		return err
	}
	return w.server.write(protocol.Frame{Kind: protocol.KindStreamItem, CorrelationID: w.correlationID, Payload: payload})
}

func (w streamWriter) End(end protocol.StreamEnd) error {
	payload, err := json.Marshal(end)
	if err != nil {
		return err
	}
	return w.server.write(protocol.Frame{Kind: protocol.KindStreamEnd, CorrelationID: w.correlationID, Payload: payload})
}
