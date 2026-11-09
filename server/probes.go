package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type prober interface {
	Probe(ctx context.Context) Outcome
	Close() error
}

func newProber(spec jobSpec) (prober, error) {
	switch spec.Profile {
	case "nq-tcp":
		return &nqTCP{spec: spec}, nil
	case "nq-udp":
		return &nqUDP{spec: spec}, nil
	case "tcp-connect":
		return &tcpConnect{spec: spec}, nil
	case "udp-generic":
		return &udpQuery{spec: spec, generic: true}, nil
	case "custom-udp":
		return &udpQuery{spec: spec}, nil
	case "dns":
		return &dnsQuery{spec: spec}, nil
	case "minecraft-java":
		return &mcJava{spec: spec}, nil
	case "minecraft-bedrock":
		return &mcBedrock{spec: spec}, nil
	default:
		return nil, fmt.Errorf("unknown profile %q", spec.Profile)
	}
}

func dialTCP(ctx context.Context, ip net.IP, port int) (net.Conn, error) {
	network := "tcp4"
	if ip.To4() == nil {
		network = "tcp6"
	}
	var d net.Dialer
	return d.DialContext(ctx, network, net.JoinHostPort(ip.String(), strconv.Itoa(port)))
}

func dialUDP(ip net.IP, port int) (*net.UDPConn, error) {
	network := "udp4"
	if ip.To4() == nil {
		network = "udp6"
	}
	raddr, err := net.ResolveUDPAddr(network, net.JoinHostPort(ip.String(), strconv.Itoa(port)))
	if err != nil {
		return nil, err
	}
	var laddr *net.UDPAddr
	if ip.To4() != nil {
		laddr = &net.UDPAddr{IP: net.IPv4zero, Port: 0}
	} else {
		laddr = &net.UDPAddr{IP: net.IPv6zero, Port: 0}
	}
	return net.DialUDP(network, laddr, raddr)
}

func classifyDial(err error) Outcome {
	if err == nil {
		return Outcome{Status: statusOK, Kind: kindConnect}
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return Outcome{Status: statusTimeout, Kind: kindConnect, Note: "连接超时"}
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return Outcome{Status: statusDNS, Kind: kindConnect, Note: "域名无法解析"}
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return Outcome{Status: statusRefused, Kind: kindConnect, Note: "连接被拒绝"}
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return Outcome{Status: statusTimeout, Kind: kindConnect, Note: "连接超时"}
	}
	return Outcome{Status: statusError, Kind: kindConnect, Note: "连接失败"}
}

func nqPacket(seq uint32, token [tokenLen]byte, size int) ([]byte, error) {
	if size < headerSize {
		size = headerSize
	}
	if size > 1400 {
		size = 1400
	}
	p := Packet{
		Version:            protocolVer,
		Type:               typeRequest,
		Sequence:           seq,
		ClientSendUnixNano: uint64(time.Now().UnixNano()),
		Token:              token,
		Payload:            make([]byte, size-headerSize),
	}
	return p.Marshal()
}

type nqTCP struct {
	spec   jobSpec
	conn   net.Conn
	reader *bufio.Reader
	seq    uint32
}

func (p *nqTCP) Close() error {
	if p.conn != nil {
		err := p.conn.Close()
		p.conn = nil
		p.reader = nil
		return err
	}
	return nil
}

func (p *nqTCP) dial(ctx context.Context) error {
	conn, err := dialTCP(ctx, p.spec.IP, p.spec.Port)
	if err != nil {
		return err
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	p.conn = conn
	p.reader = bufio.NewReaderSize(conn, headerSize+maxPayloadSize)
	return nil
}

func (p *nqTCP) Probe(ctx context.Context) Outcome {
	if p.conn == nil {
		if err := p.dial(ctx); err != nil {
			out := classifyDial(err)
			out.Reconnect = true
			if out.Note == "" {
				out.Note = "TCP 反射连接失败，将重试"
			}
			return out
		}
	}
	p.seq++
	raw, err := nqPacket(p.seq, p.spec.Echo, p.spec.PacketSize)
	if err != nil {
		return Outcome{Status: statusError, Kind: kindProbe, Note: "无法构造探测包"}
	}
	_ = p.conn.SetWriteDeadline(time.Now().Add(p.spec.Timeout))
	if _, err := p.conn.Write(raw); err != nil {
		_ = p.Close()
		return Outcome{Status: statusError, Kind: kindConnect, Reconnect: true, Note: "发送失败，连接将重连"}
	}
	start := time.Now()
	deadline := start.Add(p.spec.Timeout)
	for {
		if ctx.Err() != nil {
			return Outcome{Status: statusTimeout, Kind: kindConnect, Note: "已停止"}
		}
		_ = p.conn.SetReadDeadline(deadline)
		pkt, err := readFrame(p.reader)
		if err != nil {
			_ = p.Close()
			if ne, ok := err.(net.Error); ok && ne.Timeout() || errors.Is(err, context.DeadlineExceeded) {
				return Outcome{
					Status: statusTimeout,
					Kind:   kindProbe,
					Note:   "已发出探测，超时前没有收到回显。TCP 会重传，这不是已证实的物理丢包",
				}
			}
			return Outcome{Status: statusError, Kind: kindConnect, Reconnect: true, Note: "连接中断，将重连"}
		}
		if pkt.Type != typeReply || pkt.Sequence != p.seq {
			continue
		}
		return Outcome{
			Status: statusOK,
			Kind:   kindProbe,
			HasRtt: true,
			Rtt:    time.Since(start),
			Note:   "收到回显",
		}
	}
}

type nqUDP struct {
	spec jobSpec
	conn *net.UDPConn
	seq  uint32
}

func (p *nqUDP) Close() error {
	if p.conn != nil {
		err := p.conn.Close()
		p.conn = nil
		return err
	}
	return nil
}

func (p *nqUDP) ensure() error {
	if p.conn != nil {
		return nil
	}
	c, err := dialUDP(p.spec.IP, p.spec.Port)
	if err != nil {
		return err
	}
	p.conn = c
	return nil
}

func (p *nqUDP) Probe(ctx context.Context) Outcome {
	if err := p.ensure(); err != nil {
		return classifyDial(err)
	}
	p.seq++
	raw, err := nqPacket(p.seq, p.spec.Echo, p.spec.PacketSize)
	if err != nil {
		return Outcome{Status: statusError, Kind: kindProbe, Note: "无法构造探测包"}
	}
	start := time.Now()
	deadline := start.Add(p.spec.Timeout)
	_ = p.conn.SetWriteDeadline(deadline)
	if _, err := p.conn.Write(raw); err != nil {
		return classifyDial(err)
	}
	buf := make([]byte, 2048)
	sawInvalid := false
	for {
		if ctx.Err() != nil {
			return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "已停止"}
		}
		_ = p.conn.SetReadDeadline(deadline)
		n, err := p.conn.Read(buf)
		if err != nil {
			if errors.Is(err, syscall.ECONNREFUSED) {
				return Outcome{Status: statusRefused, Kind: kindQuery, Note: "目标端口不可达"}
			}
			if sawInvalid {
				return Outcome{Status: statusProtocol, Kind: kindProbe, Note: "收到的 UDP 包不是有效回显"}
			}
			return Outcome{
				Status: statusTimeout,
				Kind:   kindProbe,
				Note:   "未收到回显。这是探测没有应答，不是网卡上的物理丢包计数",
			}
		}
		pkt, err := ParsePacket(buf[:n])
		if err != nil || pkt.Type != typeReply {
			sawInvalid = true
			continue
		}
		if pkt.Sequence != p.seq {
			continue
		}
		return Outcome{Status: statusOK, Kind: kindProbe, HasRtt: true, Rtt: time.Since(start), Note: "收到回显"}
	}
}

type tcpConnect struct{ spec jobSpec }

func (p *tcpConnect) Close() error { return nil }

func (p *tcpConnect) Probe(ctx context.Context) Outcome {
	start := time.Now()
	conn, err := dialTCP(ctx, p.spec.IP, p.spec.Port)
	if err != nil {
		return classifyDial(err)
	}
	_ = conn.Close()
	return Outcome{Status: statusOK, Kind: kindConnect, HasRtt: true, Rtt: time.Since(start), Note: "TCP 已连通"}
}

type udpQuery struct {
	spec    jobSpec
	generic bool
	conn    *net.UDPConn
}

func (p *udpQuery) Close() error {
	if p.conn != nil {
		err := p.conn.Close()
		p.conn = nil
		return err
	}
	return nil
}

func (p *udpQuery) Probe(ctx context.Context) Outcome {
	if p.conn == nil {
		c, err := dialUDP(p.spec.IP, p.spec.Port)
		if err != nil {
			return classifyDial(err)
		}
		p.conn = c
	}
	payload := p.spec.Payload
	if p.generic {
		n := p.spec.PacketSize
		if n < 1 {
			n = 16
		}
		if n > 1400 {
			n = 1400
		}
		payload = make([]byte, n)
	}
	start := time.Now()
	deadline := start.Add(p.spec.Timeout)
	_ = p.conn.SetWriteDeadline(deadline)
	if _, err := p.conn.Write(payload); err != nil {
		return classifyDial(err)
	}
	buf := make([]byte, 2048)
	_ = p.conn.SetReadDeadline(deadline)
	n, err := p.conn.Read(buf)
	if err != nil {
		if errors.Is(err, syscall.ECONNREFUSED) {
			return Outcome{Status: statusRefused, Kind: kindQuery, Note: "目标端口不可达"}
		}
		if ctx.Err() != nil {
			return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "已停止"}
		}
		return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "没有收到 UDP 应答，不能据此断定物理丢包"}
	}
	got := buf[:n]
	if len(p.spec.Expect) > 0 {
		if len(got) < len(p.spec.Expect) || string(got[:len(p.spec.Expect)]) != string(p.spec.Expect) {
			return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "收到了数据，但和预期的响应不一致"}
		}
	}
	return Outcome{Status: statusOK, Kind: kindQuery, HasRtt: true, Rtt: time.Since(start), Note: "收到 UDP 响应"}
}

type dnsQuery struct {
	spec jobSpec
	conn *net.UDPConn
	id   uint16
}

func (p *dnsQuery) Close() error {
	if p.conn != nil {
		err := p.conn.Close()
		p.conn = nil
		return err
	}
	return nil
}

func (p *dnsQuery) Probe(ctx context.Context) Outcome {
	if p.conn == nil {
		c, err := dialUDP(p.spec.IP, p.spec.Port)
		if err != nil {
			return classifyDial(err)
		}
		p.conn = c
	}
	p.id++
	if p.id == 0 {
		p.id = 1
	}
	name := p.spec.DNSName
	if name == "" {
		name = "example.com"
	}
	query, err := dnsQueryMessage(p.id, name)
	if err != nil {
		return Outcome{Status: statusError, Kind: kindQuery, Note: "无法构造 DNS 查询"}
	}
	start := time.Now()
	deadline := start.Add(p.spec.Timeout)
	_ = p.conn.SetWriteDeadline(deadline)
	if _, err := p.conn.Write(query); err != nil {
		return classifyDial(err)
	}
	buf := make([]byte, 1500)
	for {
		if ctx.Err() != nil {
			return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "已停止"}
		}
		_ = p.conn.SetReadDeadline(deadline)
		n, err := p.conn.Read(buf)
		if err != nil {
			if errors.Is(err, syscall.ECONNREFUSED) {
				return Outcome{Status: statusRefused, Kind: kindQuery, Note: "DNS 端口不可达"}
			}
			return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "没有收到 DNS 应答，不能据此断定物理丢包"}
		}
		if n < 12 {
			return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "DNS 应答太短"}
		}
		id := binary.BigEndian.Uint16(buf[:2])
		if id != p.id {
			continue
		}
		if buf[2]&0x80 == 0 {
			return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "收到的包不是 DNS 应答"}
		}
		return Outcome{Status: statusOK, Kind: kindQuery, HasRtt: true, Rtt: time.Since(start), Note: "收到 DNS 应答"}
	}
}

func dnsQueryMessage(id uint16, name string) ([]byte, error) {
	var q []byte
	for _, label := range strings.Split(name, ".") {
		if label == "" {
			continue
		}
		if len(label) > 63 {
			return nil, errors.New("label too long")
		}
		q = append(q, byte(len(label)))
		q = append(q, label...)
	}
	q = append(q, 0, 0, 1, 0, 1)
	msg := make([]byte, 12+len(q))
	binary.BigEndian.PutUint16(msg[0:2], id)
	binary.BigEndian.PutUint16(msg[2:4], 0x0100)
	binary.BigEndian.PutUint16(msg[4:6], 1)
	copy(msg[12:], q)
	return msg, nil
}

var rakMagic = []byte{0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78}

type mcBedrock struct {
	spec jobSpec
	conn *net.UDPConn
	guid uint64
}

func (p *mcBedrock) Close() error {
	if p.conn != nil {
		err := p.conn.Close()
		p.conn = nil
		return err
	}
	return nil
}

func (p *mcBedrock) Probe(ctx context.Context) Outcome {
	if p.conn == nil {
		c, err := dialUDP(p.spec.IP, p.spec.Port)
		if err != nil {
			return classifyDial(err)
		}
		p.conn = c
		p.guid = uint64(time.Now().UnixNano())
	}
	ts := uint64(time.Now().UnixNano())
	pkt := make([]byte, 1+8+16+8)
	pkt[0] = 0x01
	binary.BigEndian.PutUint64(pkt[1:9], ts)
	copy(pkt[9:25], rakMagic)
	binary.BigEndian.PutUint64(pkt[25:33], p.guid)
	start := time.Now()
	deadline := start.Add(p.spec.Timeout)
	_ = p.conn.SetWriteDeadline(deadline)
	if _, err := p.conn.Write(pkt); err != nil {
		return classifyDial(err)
	}
	buf := make([]byte, 1500)
	sawInvalid := false
	for {
		if ctx.Err() != nil {
			return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "已停止"}
		}
		_ = p.conn.SetReadDeadline(deadline)
		n, err := p.conn.Read(buf)
		if err != nil {
			if sawInvalid {
				return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "收到的包不是有效的 RakNet Pong"}
			}
			if errors.Is(err, syscall.ECONNREFUSED) {
				return Outcome{Status: statusRefused, Kind: kindQuery, Note: "目标端口不可达"}
			}
			return Outcome{Status: statusUnknown, Kind: kindQuery, Note: "未收到 RakNet 应答，不能据此断定物理丢包"}
		}
		detail, ok := parseRakPong(buf[:n], ts)
		if !ok {
			sawInvalid = true
			continue
		}
		return Outcome{Status: statusOK, Kind: kindQuery, HasRtt: true, Rtt: time.Since(start), Note: "收到 Bedrock 应答", Detail: detail}
	}
}

func parseRakPong(b []byte, ts uint64) (map[string]string, bool) {
	if len(b) < 1+8+8+16+2 || b[0] != 0x1c {
		return nil, false
	}
	if binary.BigEndian.Uint64(b[1:9]) != ts {
		return nil, false
	}
	if string(b[17:33]) != string(rakMagic) {
		return nil, false
	}
	strlen := int(binary.BigEndian.Uint16(b[33:35]))
	if 35+strlen > len(b) {
		return nil, false
	}
	text := string(b[35 : 35+strlen])
	parts := strings.Split(text, ";")
	detail := map[string]string{}
	if len(parts) > 1 {
		detail["motd"] = parts[1]
	}
	if len(parts) > 3 {
		detail["version"] = parts[3]
	}
	if len(parts) > 5 {
		detail["players"] = parts[4] + "/" + parts[5]
	}
	return detail, true
}

type mcJava struct{ spec jobSpec }

func (p *mcJava) Close() error { return nil }

func (p *mcJava) Probe(ctx context.Context) Outcome {
	conn, err := dialTCP(ctx, p.spec.IP, p.spec.Port)
	if err != nil {
		return classifyDial(err)
	}
	defer conn.Close()
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(p.spec.Timeout)
	}
	_ = conn.SetDeadline(deadline)
	r := bufio.NewReader(conn)
	host := p.spec.Host
	if err := writeMC(conn, mcHandshake(host, p.spec.Port)); err != nil {
		return Outcome{Status: statusError, Kind: kindConnect, Note: "无法发送 Minecraft 握手"}
	}
	if err := writeMC(conn, []byte{0x00}); err != nil {
		return Outcome{Status: statusError, Kind: kindConnect, Note: "无法发送状态请求"}
	}
	payload, err := readMC(r)
	if err != nil || len(payload) < 2 || payload[0] != 0x00 {
		return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "Minecraft 状态响应无效"}
	}
	jsonText, _, err := readMCString(payload[1:])
	if err != nil {
		return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "Minecraft 状态内容无法解析"}
	}
	detail := minecraftStatusDetail(jsonText)
	nonce := time.Now().UnixNano()
	ping := []byte{0x01}
	var num [8]byte
	binary.BigEndian.PutUint64(num[:], uint64(nonce))
	ping = append(ping, num[:]...)
	start := time.Now()
	if err := writeMC(conn, ping); err != nil {
		return Outcome{Status: statusError, Kind: kindQuery, Note: "无法发送 Minecraft ping", Detail: detail}
	}
	pong, err := readMC(r)
	if err != nil || len(pong) != 9 || pong[0] != 0x01 {
		return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "没有收到有效的 Minecraft pong", Detail: detail}
	}
	if int64(binary.BigEndian.Uint64(pong[1:])) != nonce {
		return Outcome{Status: statusProtocol, Kind: kindQuery, Note: "Minecraft pong 的时间戳不匹配", Detail: detail}
	}
	return Outcome{
		Status: statusOK,
		Kind:   kindQuery,
		HasRtt: true,
		Rtt:    time.Since(start),
		Note:   "收到 Minecraft 状态和 ping 应答",
		Detail: detail,
	}
}

func mcHandshake(host string, port int) []byte {
	var p []byte
	p = append(p, 0x00)
	p = appendVarInt(p, 767)
	p = appendMCString(p, host)
	var pb [2]byte
	binary.BigEndian.PutUint16(pb[:], uint16(port))
	p = append(p, pb[:]...)
	p = appendVarInt(p, 1)
	return p
}

func minecraftStatusDetail(raw string) map[string]string {
	var body map[string]any
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		return map[string]string{}
	}
	out := map[string]string{}
	if v, ok := body["version"].(map[string]any); ok {
		if name, ok := v["name"].(string); ok {
			out["version"] = name
		}
	}
	if p, ok := body["players"].(map[string]any); ok {
		online, _ := asInt(p["online"])
		max, _ := asInt(p["max"])
		out["players"] = fmt.Sprintf("%d/%d", online, max)
	}
	if desc, ok := body["description"]; ok {
		if text := motdText(desc); text != "" {
			out["motd"] = text
		}
	}
	return out
}

func asInt(v any) (int, bool) {
	switch n := v.(type) {
	case float64:
		return int(n), true
	case int:
		return n, true
	default:
		return 0, false
	}
}

func motdText(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case map[string]any:
		var b strings.Builder
		if s, ok := t["text"].(string); ok {
			b.WriteString(s)
		}
		if extra, ok := t["extra"].([]any); ok {
			for _, e := range extra {
				b.WriteString(motdText(e))
			}
		}
		return b.String()
	default:
		return ""
	}
}

func appendVarInt(dst []byte, v int) []byte {
	u := uint32(v)
	for {
		if u&^0x7f == 0 {
			return append(dst, byte(u))
		}
		dst = append(dst, byte(u)|0x80)
		u >>= 7
	}
}

func readVarInt(r *bufio.Reader) (int, error) {
	var n uint32
	for i := 0; i < 5; i++ {
		b, err := r.ReadByte()
		if err != nil {
			return 0, err
		}
		n |= uint32(b&0x7f) << (7 * i)
		if b&0x80 == 0 {
			return int(n), nil
		}
	}
	return 0, errors.New("varint too long")
}

func appendMCString(dst []byte, s string) []byte {
	dst = appendVarInt(dst, len(s))
	return append(dst, s...)
}

func readMCString(b []byte) (string, []byte, error) {
	n, rest, err := readVarIntBytes(b)
	if err != nil || n < 0 || n > len(rest) {
		return "", nil, errors.New("bad string")
	}
	return string(rest[:n]), rest[n:], nil
}

func readVarIntBytes(b []byte) (int, []byte, error) {
	var n uint32
	for i := 0; i < 5 && i < len(b); i++ {
		by := b[i]
		n |= uint32(by&0x7f) << (7 * i)
		if by&0x80 == 0 {
			return int(n), b[i+1:], nil
		}
	}
	return 0, nil, errors.New("varint")
}

func writeMC(w io.Writer, payload []byte) error {
	frame := appendVarInt(nil, len(payload))
	frame = append(frame, payload...)
	_, err := w.Write(frame)
	return err
}

func readMC(r *bufio.Reader) ([]byte, error) {
	n, err := readVarInt(r)
	if err != nil {
		return nil, err
	}
	if n < 1 || n > 1<<20 {
		return nil, errors.New("bad packet length")
	}
	buf := make([]byte, n)
	_, err = io.ReadFull(r, buf)
	return buf, err
}
