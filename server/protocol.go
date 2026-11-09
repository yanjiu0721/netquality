// Package main implements the NetQuality reflector.
//
// Wire format (version 1), little-endian. The same layout is used for one
// UDP datagram and for one TCP frame. TCP frames are concatenated on the
// stream and split using PayloadLen; there is no extra length prefix.
//
//	Offset  Size  Field
//	0       4     Magic "NQ01"
//	4       1     Version (1)
//	5       1     Type (1 request, 2 reply)
//	6       1     Flags (reserved, send 0)
//	7       1     Reserved (0)
//	8       4     Sequence uint32
//	12      8     ClientSendUnixNano uint64
//	20      8     ServerUnixNano uint64 (0 on request)
//	28      32    Token (UTF-8, zero padded; zeros if unused)
//	60      2     PayloadLen uint16
//	62      N     Payload (opaque, echoed unchanged)
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	magic          = "NQ01"
	protocolVer    = 1
	headerSize     = 62
	tokenOffset    = 28
	tokenLen       = 32
	payloadLenOff  = 60
	maxPayloadSize = 2048

	typeRequest byte = 1
	typeReply   byte = 2
)

var (
	errShortPacket   = errors.New("packet shorter than header")
	errBadMagic      = errors.New("bad magic")
	errBadVersion    = errors.New("unsupported version")
	errBadType       = errors.New("unsupported type")
	errBadPayloadLen = errors.New("payload length out of range")
	errTrailingBytes = errors.New("trailing bytes after payload")
	errBadToken      = errors.New("token mismatch")
)

// Packet is a decoded probe frame.
type Packet struct {
	Version            byte
	Type               byte
	Flags              byte
	Sequence           uint32
	ClientSendUnixNano uint64
	ServerUnixNano     uint64
	Token              [tokenLen]byte
	Payload            []byte
}

func (p Packet) Marshal() ([]byte, error) {
	if len(p.Payload) > maxPayloadSize {
		return nil, errBadPayloadLen
	}
	buf := make([]byte, headerSize+len(p.Payload))
	copy(buf[0:4], magic)
	buf[4] = p.Version
	buf[5] = p.Type
	buf[6] = p.Flags
	buf[7] = 0
	binary.LittleEndian.PutUint32(buf[8:12], p.Sequence)
	binary.LittleEndian.PutUint64(buf[12:20], p.ClientSendUnixNano)
	binary.LittleEndian.PutUint64(buf[20:28], p.ServerUnixNano)
	copy(buf[tokenOffset:tokenOffset+tokenLen], p.Token[:])
	binary.LittleEndian.PutUint16(buf[payloadLenOff:payloadLenOff+2], uint16(len(p.Payload)))
	copy(buf[headerSize:], p.Payload)
	return buf, nil
}

// ParsePacket decodes a single frame. n is the number of bytes consumed,
// which equals the full frame size. Extra bytes are rejected so a UDP
// datagram must contain exactly one frame.
func ParsePacket(b []byte) (Packet, error) {
	if len(b) < headerSize {
		return Packet{}, errShortPacket
	}
	if string(b[0:4]) != magic {
		return Packet{}, errBadMagic
	}
	if b[4] != protocolVer {
		return Packet{}, errBadVersion
	}
	typ := b[5]
	if typ != typeRequest && typ != typeReply {
		return Packet{}, errBadType
	}
	payloadLen := int(binary.LittleEndian.Uint16(b[payloadLenOff : payloadLenOff+2]))
	if payloadLen > maxPayloadSize {
		return Packet{}, errBadPayloadLen
	}
	total := headerSize + payloadLen
	if len(b) < total {
		return Packet{}, fmt.Errorf("%w: need %d bytes, have %d", errShortPacket, total, len(b))
	}
	if len(b) != total {
		return Packet{}, errTrailingBytes
	}
	var p Packet
	p.Version = b[4]
	p.Type = typ
	p.Flags = b[6]
	p.Sequence = binary.LittleEndian.Uint32(b[8:12])
	p.ClientSendUnixNano = binary.LittleEndian.Uint64(b[12:20])
	p.ServerUnixNano = binary.LittleEndian.Uint64(b[20:28])
	copy(p.Token[:], b[tokenOffset:tokenOffset+tokenLen])
	if payloadLen > 0 {
		p.Payload = append([]byte(nil), b[headerSize:total]...)
	} else {
		p.Payload = []byte{}
	}
	return p, nil
}

// tokenBytes normalizes a configured shared token into the 32-byte field.
// Empty means "no token required".
func tokenBytes(s string) ([tokenLen]byte, error) {
	var out [tokenLen]byte
	if s == "" {
		return out, nil
	}
	b := []byte(s)
	if len(b) > tokenLen {
		return out, fmt.Errorf("token longer than %d bytes", tokenLen)
	}
	copy(out[:], b)
	return out, nil
}

func tokenMatches(got [tokenLen]byte, want [tokenLen]byte, required bool) bool {
	if !required {
		return true
	}
	return got == want
}
