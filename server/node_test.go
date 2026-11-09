package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSafetyBlocksPrivateAndMetadata(t *testing.T) {
	ctx := context.Background()
	cases := []string{"127.0.0.1", "10.1.2.3", "192.168.1.1", "169.254.169.254", "169.254.1.1", "::1", "metadata.google.internal", "localhost"}
	for _, host := range cases {
		if _, err := targetOK(ctx, nil, host, false, nil); !errors.Is(err, errForbiddenTarget) {
			t.Fatalf("%s: got %v", host, err)
		}
	}
	if _, err := targetOK(ctx, nil, "169.254.169.254", true, nil); !errors.Is(err, errForbiddenTarget) {
		t.Fatalf("metadata must stay blocked with allow-private: %v", err)
	}
	if _, err := targetOK(ctx, nil, "127.0.0.1", true, nil); err != nil {
		t.Fatal(err)
	}
	_, n, _ := net.ParseCIDR("10.1.2.0/24")
	ip, err := targetOK(ctx, nil, "10.1.2.9", false, []*net.IPNet{n})
	if err != nil || !ip.Equal(net.ParseIP("10.1.2.9")) {
		t.Fatalf("allow net: %v %v", ip, err)
	}
	_, err = targetOK(ctx, nil, "10.9.9.9", false, []*net.IPNet{n})
	if !errors.Is(err, errForbiddenTarget) {
		t.Fatalf("outside allow net: %v", err)
	}
	if _, err := targetOK(ctx, nil, "1.1.1.1", false, nil); err != nil {
		t.Fatal(err)
	}
	rebinding := stubResolver{[]net.IP{net.ParseIP("1.1.1.1"), net.ParseIP("10.0.0.1")}}
	if _, err := targetOK(ctx, rebinding, "example.com", false, nil); !errors.Is(err, errForbiddenTarget) {
		t.Fatalf("rebinding: %v", err)
	}
}

type stubResolver struct{ ips []net.IP }

func (s stubResolver) LookupIPAddr(context.Context, string) ([]net.IPAddr, error) {
	out := make([]net.IPAddr, len(s.ips))
	for i, ip := range s.ips {
		out[i] = net.IPAddr{IP: ip}
	}
	return out, nil
}

func TestPublicAndPrivateAuth(t *testing.T) {
	public := httptest.NewServer(newNode("", true, nil, testLimits()).Handler())
	defer public.Close()
	res, err := http.Post(public.URL+"/v1/jobs", "application/json", strings.NewReader(`{"target":"127.0.0.1","port":1,"profile":"tcp-connect","durationSec":1,"intervalMs":200,"timeoutMs":200}`))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("public status %d", res.StatusCode)
	}
	info, err := http.Get(public.URL + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	defer info.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(info.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["visibility"] != "public" || body["authRequired"] != false {
		t.Fatalf("info %+v", body)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var accepted atomic.Int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			accepted.Add(1)
			c.Close()
		}
	}()
	port := ln.Addr().(*net.TCPAddr).Port
	private := httptest.NewServer(newNode("secret-token", true, nil, testLimits()).Handler())
	defer private.Close()
	payload := `{"target":"127.0.0.1","port":` + itoa(port) + `,"profile":"tcp-connect","durationSec":2,"intervalMs":200,"timeoutMs":300}`
	post := func(token string) *http.Response {
		t.Helper()
		req, err := http.NewRequest(http.MethodPost, private.URL+"/v1/jobs", strings.NewReader(payload))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res
	}
	if post("").StatusCode != http.StatusUnauthorized {
		t.Fatal("missing token was accepted")
	}
	if post("wrong").StatusCode != http.StatusUnauthorized {
		t.Fatal("wrong token was accepted")
	}
	time.Sleep(200 * time.Millisecond)
	if accepted.Load() != 0 {
		t.Fatalf("auth failure dialed the target %d times", accepted.Load())
	}
	if post("secret-token").StatusCode != http.StatusCreated {
		t.Fatal("good token was rejected")
	}
}

func TestNodeNQAndTCPAndUDP(t *testing.T) {
	tcpLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	echo := &Server{}
	go echo.ServeTCP(tcpLn)
	go echo.ServeUDP(udpConn)
	defer echo.Close()

	node := newNode("", true, nil, testLimits())
	srv := httptest.NewServer(node.Handler())
	defer srv.Close()

	tcpPort := tcpLn.Addr().(*net.TCPAddr).Port
	udpPort := udpConn.LocalAddr().(*net.UDPAddr).Port
	tcpJob := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": tcpPort, "profile": "nq-tcp",
		"intervalMs": 200, "timeoutMs": 800, "durationSec": 3, "packetSize": 80,
	})
	sample := readOneSample(t, srv.URL, "", tcpJob)
	if sample.Status != statusOK || sample.RttMs == nil || *sample.RttMs <= 0 {
		t.Fatalf("nq tcp %+v", sample)
	}
	if sample.Summary.ProbeLossPct == nil || *sample.Summary.ProbeLossPct != 0 {
		t.Fatalf("loss %+v", sample.Summary)
	}

	udpJob := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": udpPort, "profile": "nq-udp",
		"intervalMs": 200, "timeoutMs": 800, "durationSec": 3, "packetSize": 80,
	})
	sample = readOneSample(t, srv.URL, "", udpJob)
	if sample.Status != statusOK || sample.RttMs == nil || *sample.RttMs <= 0 {
		t.Fatalf("nq udp %+v", sample)
	}

	okJob := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": tcpPort, "profile": "tcp-connect",
		"intervalMs": 200, "timeoutMs": 800, "durationSec": 2,
	})
	sample = readOneSample(t, srv.URL, "", okJob)
	if sample.Status != statusOK || sample.Kind != kindConnect {
		t.Fatalf("tcp connect %+v", sample)
	}

	refused := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": 1, "profile": "tcp-connect",
		"intervalMs": 200, "timeoutMs": 400, "durationSec": 2,
	})
	sample = readOneSample(t, srv.URL, "", refused)
	if sample.Status != statusRefused || sample.Summary.FailurePct == nil || *sample.Summary.FailurePct != 100 {
		t.Fatalf("refused %+v", sample)
	}
	if sample.Summary.ProbeLossPct != nil {
		t.Fatalf("tcp connect must not report probe loss %+v", sample.Summary)
	}
}

func TestGenericUDPUnknownAndEcho(t *testing.T) {
	blackhole, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer blackhole.Close()
	go func() {
		buf := make([]byte, 64)
		for {
			_, _, err := blackhole.ReadFromUDP(buf)
			if err != nil {
				return
			}
		}
	}()
	node := httptest.NewServer(newNode("", true, nil, testLimits()).Handler())
	defer node.Close()
	id := createJob(t, node.URL, "", map[string]any{
		"target": "127.0.0.1", "port": blackhole.LocalAddr().(*net.UDPAddr).Port,
		"profile": "udp-generic", "intervalMs": 200, "timeoutMs": 250, "durationSec": 2, "packetSize": 16,
	})
	sample := readOneSample(t, node.URL, "", id)
	if sample.Status != statusUnknown || sample.Summary.ProbeLossPct != nil {
		t.Fatalf("unknown %+v", sample)
	}
	if sample.Summary.UnknownPct == nil || *sample.Summary.UnknownPct != 100 {
		t.Fatalf("unknown pct %+v", sample.Summary)
	}

	echo, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 256)
		for {
			n, addr, err := echo.ReadFromUDP(buf)
			if err != nil {
				return
			}
			_, _ = echo.WriteToUDP(append([]byte(nil), buf[:n]...), addr)
		}
	}()
	id = createJob(t, node.URL, "", map[string]any{
		"target": "127.0.0.1", "port": echo.LocalAddr().(*net.UDPAddr).Port,
		"profile": "custom-udp", "intervalMs": 200, "timeoutMs": 800, "durationSec": 2,
		"payloadHex": "0102", "expectHex": "0102",
	})
	sample = readOneSample(t, node.URL, "", id)
	if sample.Status != statusOK || sample.RttMs == nil {
		t.Fatalf("custom echo %+v", sample)
	}
	id = createJob(t, node.URL, "", map[string]any{
		"target": "127.0.0.1", "port": echo.LocalAddr().(*net.UDPAddr).Port,
		"profile": "custom-udp", "intervalMs": 200, "timeoutMs": 400, "durationSec": 2,
		"payloadHex": "0102", "expectHex": "ffff",
	})
	sample = readOneSample(t, node.URL, "", id)
	if sample.Status != statusProtocol {
		t.Fatalf("mismatch %+v", sample)
	}
}

func TestMinecraftJavaAndBedrockFixtures(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go serveFakeJava(ln)
	udp, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	go serveFakeBedrock(udp, true)

	node := httptest.NewServer(newNode("", true, nil, testLimits()).Handler())
	defer node.Close()
	id := createJob(t, node.URL, "", map[string]any{
		"target": "127.0.0.1", "port": ln.Addr().(*net.TCPAddr).Port,
		"profile": "minecraft-java", "intervalMs": 200, "timeoutMs": 1000, "durationSec": 3,
	})
	sample := readOneSample(t, node.URL, "", id)
	if sample.Status != statusOK || sample.Detail["motd"] != "Hello" || sample.Detail["version"] != "1.21.1" || sample.Detail["players"] != "3/20" {
		t.Fatalf("java %+v", sample)
	}
	if sample.RttMs == nil || *sample.RttMs < 0 || sample.Summary.FailurePct == nil || *sample.Summary.FailurePct != 0 {
		t.Fatalf("java rtt %+v", sample)
	}

	id = createJob(t, node.URL, "", map[string]any{
		"target": "127.0.0.1", "port": udp.LocalAddr().(*net.UDPAddr).Port,
		"profile": "minecraft-bedrock", "intervalMs": 200, "timeoutMs": 1000, "durationSec": 3,
	})
	sample = readOneSample(t, node.URL, "", id)
	if sample.Status != statusOK || sample.Detail["motd"] != "Bed" || sample.RttMs == nil {
		t.Fatalf("bedrock %+v", sample)
	}

	bad, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer bad.Close()
	go serveFakeBedrock(bad, false)
	id = createJob(t, node.URL, "", map[string]any{
		"target": "127.0.0.1", "port": bad.LocalAddr().(*net.UDPAddr).Port,
		"profile": "minecraft-bedrock", "intervalMs": 200, "timeoutMs": 400, "durationSec": 2,
	})
	sample = readOneSample(t, node.URL, "", id)
	if sample.Status != statusProtocol {
		t.Fatalf("bad magic %+v", sample)
	}
}

func TestDNSAndDeleteAndLimits(t *testing.T) {
	dns, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer dns.Close()
	go func() {
		buf := make([]byte, 512)
		for {
			n, addr, err := dns.ReadFromUDP(buf)
			if err != nil || n < 2 {
				return
			}
			reply := []byte{buf[0], buf[1], 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0}
			_, _ = dns.WriteToUDP(reply, addr)
		}
	}()
	limits := testLimits()
	limits.MaxJobs = 1
	node := newNode("", true, nil, limits)
	srv := httptest.NewServer(node.Handler())
	defer srv.Close()
	id := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": dns.LocalAddr().(*net.UDPAddr).Port,
		"profile": "dns", "dnsName": "example.com", "intervalMs": 200, "timeoutMs": 800, "durationSec": 5,
	})
	res, err := http.Post(srv.URL+"/v1/jobs", "application/json", strings.NewReader(`{"target":"127.0.0.1","port":9,"profile":"tcp-connect","durationSec":5,"intervalMs":200,"timeoutMs":200}`))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("limit status %d", res.StatusCode)
	}
	del, err := http.NewRequest(http.MethodDelete, srv.URL+"/v1/jobs/"+id, nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err = http.DefaultClient.Do(del)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("delete %d", res.StatusCode)
	}
	deadline := time.Now().Add(2 * time.Second)
	for node.jobCount() != 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if node.jobCount() != 0 {
		t.Fatalf("job still running: %d", node.jobCount())
	}
	again := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": dns.LocalAddr().(*net.UDPAddr).Port,
		"profile": "dns", "dnsName": "example.com", "intervalMs": 200, "timeoutMs": 800, "durationSec": 3,
	})
	sample := readOneSample(t, srv.URL, "", again)
	if sample.Status != statusOK || sample.RttMs == nil {
		t.Fatalf("dns %+v", sample)
	}
}

func TestBookIgnoresPendingAndNQConnectFailure(t *testing.T) {
	b := &sampleBook{profile: "nq-tcp"}
	s := b.summary()
	if s.ProbeLossPct != nil || s.Completed != 0 {
		t.Fatalf("empty book %+v", s)
	}
	b.add(Outcome{Status: statusRefused, Kind: kindConnect, Reconnect: true})
	s = b.summary()
	if s.ProbeLossPct != nil || s.Reconnects != 1 {
		t.Fatalf("connect failure counted as loss %+v", s)
	}
	b.add(Outcome{Status: statusTimeout, Kind: kindProbe})
	b.add(Outcome{Status: statusOK, Kind: kindProbe, HasRtt: true, Rtt: time.Millisecond})
	s = b.summary()
	if s.ProbeLossPct == nil || *s.ProbeLossPct != 50 {
		t.Fatalf("probe loss %+v", s)
	}
	u := &sampleBook{profile: "udp-generic"}
	u.add(Outcome{Status: statusUnknown, Kind: kindQuery})
	if u.summary().ProbeLossPct != nil || u.summary().UnknownPct == nil {
		t.Fatalf("unknown %+v", u.summary())
	}
}

func TestLateUDPReplyIgnored(t *testing.T) {
	echo, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, addr, err := echo.ReadFromUDP(buf)
			if err != nil {
				return
			}
			pkt, err := ParsePacket(append([]byte(nil), buf[:n]...))
			if err != nil || pkt.Type != typeRequest {
				continue
			}
			pkt.Type = typeReply
			pkt.ServerUnixNano = uint64(time.Now().UnixNano())
			raw, err := pkt.Marshal()
			if err != nil {
				continue
			}
			seq := pkt.Sequence
			dest := &net.UDPAddr{IP: append(net.IP(nil), addr.IP...), Port: addr.Port}
			go func(seq uint32, raw []byte, dest *net.UDPAddr) {
				if seq == 1 {
					time.Sleep(400 * time.Millisecond)
				}
				_, _ = echo.WriteToUDP(raw, dest)
			}(seq, raw, dest)
		}
	}()
	p := &nqUDP{spec: jobSpec{
		IP: net.IPv4(127, 0, 0, 1), Port: echo.LocalAddr().(*net.UDPAddr).Port,
		Timeout: 150 * time.Millisecond, PacketSize: 80,
	}}
	defer p.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	first := p.Probe(ctx)
	if first.Status != statusTimeout {
		t.Fatalf("first %+v", first)
	}
	second := p.Probe(ctx)
	if second.Status != statusOK {
		t.Fatalf("second %+v", second)
	}
}

func testLimits() Limits {
	l := defaultLimits()
	l.MaxJobs = 4
	l.MinInterval = 200 * time.Millisecond
	l.MaxDuration = 10 * time.Second
	return l
}

func createJob(t *testing.T, base, token string, body map[string]any) string {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, base+"/v1/jobs", strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusCreated {
		b, _ := io.ReadAll(res.Body)
		t.Fatalf("create %d %s", res.StatusCode, b)
	}
	var out struct {
		JobID string `json:"jobId"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.JobID == "" {
		t.Fatal("empty job id")
	}
	return out.JobID
}

func readOneSample(t *testing.T, base, token, id string) sampleMsg {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, base+"/v1/jobs/"+id+"/stream", nil)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	req = req.WithContext(ctx)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(res.Body)
		t.Fatalf("stream %d %s", res.StatusCode, b)
	}
	sc := bufio.NewScanner(res.Body)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var msg sampleMsg
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &msg); err != nil {
			t.Fatal(err)
		}
		if msg.Status == "" || msg.Status == "pending" {
			continue
		}
		return msg
	}
	t.Fatal(sc.Err())
	return sampleMsg{}
}

func serveFakeJava(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func(conn net.Conn) {
			defer conn.Close()
			r := bufio.NewReader(conn)
			if _, err := readMC(r); err != nil {
				return
			}
			if _, err := readMC(r); err != nil {
				return
			}
			status := []byte(`{"version":{"name":"1.21.1","protocol":767},"players":{"online":3,"max":20},"description":{"text":"Hello"}}`)
			payload := appendMCString([]byte{0x00}, string(status))
			if err := writeMC(conn, payload); err != nil {
				return
			}
			ping, err := readMC(r)
			if err != nil {
				return
			}
			_ = writeMC(conn, ping)
		}(c)
	}
}

func serveFakeBedrock(conn *net.UDPConn, good bool) {
	buf := make([]byte, 1500)
	for {
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil || n < 33 {
			return
		}
		ts := binary.BigEndian.Uint64(buf[1:9])
		motd := "MCPE;Bed;844;1.21.50;1;10;0;world;Survival;1;19132;0;"
		body := make([]byte, 1+8+8+16+2+len(motd))
		body[0] = 0x1c
		binary.BigEndian.PutUint64(body[1:9], ts)
		binary.BigEndian.PutUint64(body[9:17], 99)
		copy(body[17:33], rakMagic)
		if !good {
			body[17] = 0x11
		}
		binary.BigEndian.PutUint16(body[33:35], uint16(len(motd)))
		copy(body[35:], motd)
		_, _ = conn.WriteToUDP(body, addr)
	}
}

func itoa(n int) string { return strconv.Itoa(n) }
