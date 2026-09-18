package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	Magic         uint32 = 0x4b534831 // "KSH1"
	HeaderSize           = 24
	ProtocolMajor uint16 = 1
	ProtocolMinor uint16 = 0
	MaxPayload           = 64 << 20
)

type MessageKind uint16

const (
	KindHello MessageKind = 1 + iota
	KindHelloAck
	KindRequest
	KindResponse
	KindError
	KindStreamItem
	KindStreamEnd
	KindCancel
	KindShutdown
	KindPing
	KindPong
)

type Frame struct {
	Kind          MessageKind
	Flags         uint32
	CorrelationID uint64
	Payload       []byte
}

func ReadFrame(r io.Reader) (Frame, error) {
	var header [HeaderSize]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return Frame{}, err
	}
	if binary.LittleEndian.Uint32(header[0:4]) != Magic {
		return Frame{}, errors.New("invalid KubeShell IPC magic")
	}
	major := binary.LittleEndian.Uint16(header[4:6])
	if major != ProtocolMajor {
		return Frame{}, fmt.Errorf("unsupported protocol major %d", major)
	}
	kind := MessageKind(binary.LittleEndian.Uint16(header[8:10]))
	flags := binary.LittleEndian.Uint32(header[10:14])
	correlationID := binary.LittleEndian.Uint64(header[14:22])
	payloadLength := binary.LittleEndian.Uint16(header[22:24])

	// Large payloads use an extended length prefix in the first four payload bytes.
	// Most control frames stay within the compact 16-bit header, while Kubernetes
	// JSON bodies are allowed to use the extended form without changing ABI v1.
	length := uint32(payloadLength)
	if payloadLength == 0xffff {
		var ext [4]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return Frame{}, err
		}
		length = binary.LittleEndian.Uint32(ext[:])
	}
	if length > MaxPayload {
		return Frame{}, fmt.Errorf("payload length %d exceeds protocol limit", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return Frame{}, err
	}
	return Frame{Kind: kind, Flags: flags, CorrelationID: correlationID, Payload: payload}, nil
}

func WriteFrame(w io.Writer, frame Frame) error {
	if len(frame.Payload) > MaxPayload {
		return fmt.Errorf("payload length %d exceeds protocol limit", len(frame.Payload))
	}
	var header [HeaderSize]byte
	binary.LittleEndian.PutUint32(header[0:4], Magic)
	binary.LittleEndian.PutUint16(header[4:6], ProtocolMajor)
	binary.LittleEndian.PutUint16(header[6:8], ProtocolMinor)
	binary.LittleEndian.PutUint16(header[8:10], uint16(frame.Kind))
	binary.LittleEndian.PutUint32(header[10:14], frame.Flags)
	binary.LittleEndian.PutUint64(header[14:22], frame.CorrelationID)

	if len(frame.Payload) < 0xffff {
		binary.LittleEndian.PutUint16(header[22:24], uint16(len(frame.Payload)))
		if _, err := w.Write(header[:]); err != nil {
			return err
		}
	} else {
		binary.LittleEndian.PutUint16(header[22:24], 0xffff)
		if _, err := w.Write(header[:]); err != nil {
			return err
		}
		var ext [4]byte
		binary.LittleEndian.PutUint32(ext[:], uint32(len(frame.Payload)))
		if _, err := w.Write(ext[:]); err != nil {
			return err
		}
	}
	if len(frame.Payload) == 0 {
		return nil
	}
	_, err := w.Write(frame.Payload)
	return err
}
