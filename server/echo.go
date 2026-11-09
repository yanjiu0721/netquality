package main

import (
	"bufio"
	"errors"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// Server is a TCP and UDP echo reflector for probe frames.
type Server struct {
	Token    [tokenLen]byte
	Required bool
	Verbose  bool

	requests atomic.Uint64
	replies  atomic.Uint64
	rejected atomic.Uint64

	lisMu       sync.Mutex
	tcpListener net.Listener
	udpConn     *net.UDPConn

	wg sync.WaitGroup
}

// HandlePacket validates a request and returns the reply bytes.
// Invalid packets return ok=false and are not answered.
func (s *Server) HandlePacket(p Packet, now time.Time) ([]byte, bool) {
	s.requests.Add(1)
	if p.Type != typeRequest || p.Version != protocolVer {
		s.rejected.Add(1)
		return nil, false
	}
	if !tokenMatches(p.Token, s.Token, s.Required) {
		s.rejected.Add(1)
		if s.Verbose {
			log.Printf("reject seq=%d: token mismatch", p.Sequence)
		}
		return nil, false
	}
	p.Type = typeReply
	p.ServerUnixNano = uint64(now.UnixNano())
	buf, err := p.Marshal()
	if err != nil {
		s.rejected.Add(1)
		return nil, false
	}
	s.replies.Add(1)
	if s.Verbose {
		log.Printf("echo seq=%d bytes=%d", p.Sequence, len(buf))
	}
	return buf, true
}

func (s *Server) Stats() (requests, replies, rejected uint64) {
	return s.requests.Load(), s.replies.Load(), s.rejected.Load()
}

// ServeTCP accepts connections until the listener is closed.
func (s *Server) ServeTCP(ln net.Listener) {
	s.lisMu.Lock()
	s.tcpListener = ln
	s.lisMu.Unlock()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("tcp accept: %v", err)
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.handleTCPConn(conn)
		}()
	}
}

func (s *Server) handleTCPConn(conn net.Conn) {
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		// Go already defaults NoDelay to true; keep it explicit so echoes are
		// not held by Nagle and RTT stays honest.
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(30 * time.Second)
	}
	remote := conn.RemoteAddr().String()
	if s.Verbose {
		log.Printf("tcp connected %s", remote)
	}
	r := bufio.NewReaderSize(conn, headerSize+maxPayloadSize)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Minute))
		pkt, err := readFrame(r)
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) && s.Verbose {
				log.Printf("tcp %s read: %v", remote, err)
			}
			return
		}
		reply, ok := s.HandlePacket(pkt, time.Now())
		if !ok {
			continue
		}
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if _, err := conn.Write(reply); err != nil {
			if s.Verbose {
				log.Printf("tcp %s write: %v", remote, err)
			}
			return
		}
	}
}

// readFrame reads exactly one frame from a TCP stream.
func readFrame(r *bufio.Reader) (Packet, error) {
	hdr := make([]byte, headerSize)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return Packet{}, err
	}
	if string(hdr[0:4]) != magic {
		return Packet{}, errBadMagic
	}
	if hdr[4] != protocolVer {
		return Packet{}, errBadVersion
	}
	payloadLen := int(binaryUint16(hdr[payloadLenOff : payloadLenOff+2]))
	if payloadLen > maxPayloadSize {
		return Packet{}, errBadPayloadLen
	}
	buf := make([]byte, headerSize+payloadLen)
	copy(buf, hdr)
	if payloadLen > 0 {
		if _, err := io.ReadFull(r, buf[headerSize:]); err != nil {
			return Packet{}, err
		}
	}
	return ParsePacket(buf)
}

func binaryUint16(b []byte) uint16 {
	return uint16(b[0]) | uint16(b[1])<<8
}

// ServeUDP reads datagrams until the socket is closed.
func (s *Server) ServeUDP(conn *net.UDPConn) {
	s.lisMu.Lock()
	s.udpConn = conn
	s.lisMu.Unlock()
	buf := make([]byte, headerSize+maxPayloadSize+64)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Minute))
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			log.Printf("udp read: %v", err)
			continue
		}
		pkt, err := ParsePacket(buf[:n])
		if err != nil {
			s.requests.Add(1)
			s.rejected.Add(1)
			if s.Verbose {
				log.Printf("udp %s bad packet: %v", addr, err)
			}
			continue
		}
		reply, ok := s.HandlePacket(pkt, time.Now())
		if !ok {
			continue
		}
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if _, err := conn.WriteToUDP(reply, addr); err != nil && s.Verbose {
			log.Printf("udp %s write: %v", addr, err)
		}
	}
}

// Close stops listeners. Existing TCP handlers exit on their next I/O error.
func (s *Server) Close() {
	s.lisMu.Lock()
	tcp := s.tcpListener
	udp := s.udpConn
	s.lisMu.Unlock()
	if tcp != nil {
		_ = tcp.Close()
	}
	if udp != nil {
		_ = udp.Close()
	}
}
