package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

func TestGoldenRequest(t *testing.T) {
	var p Packet
	p.Version = protocolVer
	p.Type = typeRequest
	p.Sequence = 1
	p.ClientSendUnixNano = 1000
	p.Payload = []byte{0x01, 0x02, 0x03, 0x04}

	got, err := p.Marshal()
	if err != nil {
		t.Fatal(err)
	}

	want := goldenRequest()
	if !bytes.Equal(got, want) {
		t.Fatalf("golden mismatch\n got %x\nwant %x", got, want)
	}

	back, err := ParsePacket(got)
	if err != nil {
		t.Fatal(err)
	}
	if back.Sequence != 1 || back.ClientSendUnixNano != 1000 || back.Type != typeRequest {
		t.Fatalf("round trip fields: %+v", back)
	}
	if !bytes.Equal(back.Payload, p.Payload) {
		t.Fatalf("payload %x", back.Payload)
	}
}

func TestRejects(t *testing.T) {
	good := goldenRequest()
	if _, err := ParsePacket(good[:10]); err == nil {
		t.Fatal("expected short packet error")
	}
	badMagic := append([]byte(nil), good...)
	badMagic[0] = 'X'
	if _, err := ParsePacket(badMagic); err != errBadMagic {
		t.Fatalf("magic: %v", err)
	}
	badVer := append([]byte(nil), good...)
	badVer[4] = 9
	if _, err := ParsePacket(badVer); err != errBadVersion {
		t.Fatalf("version: %v", err)
	}
	trailing := append(append([]byte(nil), good...), 0xFF)
	if _, err := ParsePacket(trailing); err != errTrailingBytes {
		t.Fatalf("trailing: %v", err)
	}
}

func TestTokenRequired(t *testing.T) {
	tok, err := tokenBytes("secret")
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Token: tok, Required: true}
	var p Packet
	p.Version = protocolVer
	p.Type = typeRequest
	p.Sequence = 7
	p.ClientSendUnixNano = 42
	p.Payload = []byte("hi")
	if _, ok := s.HandlePacket(p, time.Unix(0, 99)); ok {
		t.Fatal("expected token rejection")
	}
	p.Token = tok
	reply, ok := s.HandlePacket(p, time.Unix(0, 99))
	if !ok {
		t.Fatal("expected accept")
	}
	back, err := ParsePacket(reply)
	if err != nil {
		t.Fatal(err)
	}
	if back.Type != typeReply || back.Sequence != 7 || back.ClientSendUnixNano != 42 || back.ServerUnixNano != 99 {
		t.Fatalf("reply %+v", back)
	}
	if string(back.Payload) != "hi" || back.Token != tok {
		t.Fatalf("echo mismatch")
	}
}

func TestTokenTooLong(t *testing.T) {
	if _, err := tokenBytes("0123456789abcdef0123456789abcdefX"); err == nil {
		t.Fatal("expected error")
	}
}

func TestUDPAndTCPEcho(t *testing.T) {
	s := &Server{}

	udpAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer udpConn.Close()
	go s.ServeUDP(udpConn)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go s.ServeTCP(ln)

	payload := bytes.Repeat([]byte{0xAB}, 16)
	req := Packet{
		Version:            protocolVer,
		Type:               typeRequest,
		Sequence:           3,
		ClientSendUnixNano: uint64(time.Now().UnixNano()),
		Payload:            payload,
	}
	raw, err := req.Marshal()
	if err != nil {
		t.Fatal(err)
	}

	clientUDP, err := net.DialUDP("udp", nil, udpConn.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer clientUDP.Close()
	if _, err := clientUDP.Write(raw); err != nil {
		t.Fatal(err)
	}
	_ = clientUDP.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 2048)
	n, err := clientUDP.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	assertReply(t, buf[:n], req)

	tcpClient, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer tcpClient.Close()
	req.Sequence = 4
	raw, _ = req.Marshal()
	// Two frames back-to-back to prove TCP framing.
	if _, err := tcpClient.Write(append(append([]byte{}, raw...), raw...)); err != nil {
		t.Fatal(err)
	}
	_ = tcpClient.SetReadDeadline(time.Now().Add(2 * time.Second))
	got := make([]byte, len(raw)*2)
	if _, err := ioReadFull(tcpClient, got); err != nil {
		t.Fatal(err)
	}
	assertReply(t, got[:len(raw)], req)
	assertReply(t, got[len(raw):], req)
}

func assertReply(t *testing.T, raw []byte, req Packet) {
	t.Helper()
	p, err := ParsePacket(raw)
	if err != nil {
		t.Fatal(err)
	}
	if p.Type != typeReply {
		t.Fatalf("type %d", p.Type)
	}
	if p.Sequence != req.Sequence || p.ClientSendUnixNano != req.ClientSendUnixNano {
		t.Fatalf("identity not preserved: %+v", p)
	}
	if !bytes.Equal(p.Payload, req.Payload) {
		t.Fatalf("payload changed")
	}
	if p.ServerUnixNano == 0 {
		t.Fatal("server timestamp not set")
	}
}

func ioReadFull(c net.Conn, buf []byte) (int, error) {
	n := 0
	for n < len(buf) {
		r, err := c.Read(buf[n:])
		n += r
		if err != nil {
			return n, err
		}
	}
	return n, nil
}

func goldenRequest() []byte {
	buf := make([]byte, headerSize+4)
	copy(buf[0:4], "NQ01")
	buf[4] = 1
	buf[5] = 1
	binary.LittleEndian.PutUint32(buf[8:12], 1)
	binary.LittleEndian.PutUint64(buf[12:20], 1000)
	binary.LittleEndian.PutUint16(buf[payloadLenOff:payloadLenOff+2], 4)
	copy(buf[headerSize:], []byte{1, 2, 3, 4})
	return buf
}
