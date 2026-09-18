package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	cases := [][]byte{nil, []byte("small"), bytes.Repeat([]byte("x"), 70000)}
	for _, payload := range cases {
		var b bytes.Buffer
		want := Frame{Kind: KindRequest, Flags: 7, CorrelationID: 42, Payload: payload}
		if err := WriteFrame(&b, want); err != nil {
			t.Fatal(err)
		}
		got, err := ReadFrame(&b)
		if err != nil {
			t.Fatal(err)
		}
		if got.Kind != want.Kind || got.Flags != want.Flags || got.CorrelationID != want.CorrelationID || !bytes.Equal(got.Payload, want.Payload) {
			t.Fatalf("round trip mismatch: %#v", got)
		}
	}
}

func TestReadFrameRejectsInvalidMagic(t *testing.T) {
	var b bytes.Buffer
	if err := WriteFrame(&b, Frame{Kind: KindPing, CorrelationID: 9}); err != nil {
		t.Fatal(err)
	}
	wire := b.Bytes()
	wire[0] ^= 0xff
	if _, err := ReadFrame(bytes.NewReader(wire)); err == nil {
		t.Fatal("ReadFrame accepted an invalid protocol magic")
	}
}

func TestReadFrameRejectsUnsupportedMajor(t *testing.T) {
	var b bytes.Buffer
	if err := WriteFrame(&b, Frame{Kind: KindPing, CorrelationID: 9}); err != nil {
		t.Fatal(err)
	}
	wire := b.Bytes()
	wire[4] = byte(ProtocolMajor + 1)
	wire[5] = 0
	if _, err := ReadFrame(bytes.NewReader(wire)); err == nil {
		t.Fatal("ReadFrame accepted an unsupported protocol major")
	}
}

func TestFrameRejectsOversizedPayload(t *testing.T) {
	payload := make([]byte, MaxPayload+1)
	if err := WriteFrame(&bytes.Buffer{}, Frame{Kind: KindRequest, Payload: payload}); err == nil {
		t.Fatal("WriteFrame accepted a payload larger than MaxPayload")
	}

	var wire bytes.Buffer
	var header [HeaderSize]byte
	binary.LittleEndian.PutUint32(header[0:4], Magic)
	binary.LittleEndian.PutUint16(header[4:6], ProtocolMajor)
	binary.LittleEndian.PutUint16(header[8:10], uint16(KindRequest))
	binary.LittleEndian.PutUint16(header[22:24], 0xffff)
	wire.Write(header[:])
	var ext [4]byte
	binary.LittleEndian.PutUint32(ext[:], MaxPayload+1)
	wire.Write(ext[:])
	if _, err := ReadFrame(&wire); err == nil {
		t.Fatal("ReadFrame accepted an extended payload length larger than MaxPayload")
	}
}
