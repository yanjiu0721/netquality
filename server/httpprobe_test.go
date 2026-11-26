// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"
)

func TestFilterFamily(t *testing.T) {
	v4 := net.ParseIP("1.1.1.1")
	v6 := net.ParseIP("2001:db8::1")
	both := []net.IP{v4, v6}
	only4, err := filterFamily("example.com", both, true, false)
	if err != nil || len(only4) != 1 || !only4[0].Equal(v4) {
		t.Fatalf("v4 only: %v %v", only4, err)
	}
	only6, err := filterFamily("example.com", both, false, true)
	if err != nil || len(only6) != 1 || !only6[0].Equal(v6) {
		t.Fatalf("v6 only: %v %v", only6, err)
	}
	if _, err := filterFamily("example.com", both, false, false); err == nil || !strings.Contains(err.Error(), "都已关闭") {
		t.Fatalf("both off: %v", err)
	}
	if _, err := filterFamily("1.1.1.1", []net.IP{v4}, false, true); err == nil || !strings.Contains(err.Error(), "IPv4") {
		t.Fatalf("literal v4: %v", err)
	}
	if _, err := filterFamily("2001:db8::1", []net.IP{v6}, true, false); err == nil || !strings.Contains(err.Error(), "IPv6") {
		t.Fatalf("literal v6: %v", err)
	}
}

func TestHTTPRedirectStatusIsNotLoss(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/a", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/b", http.StatusFound)
	})
	mux.HandleFunc("/b", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/c", http.StatusMovedPermanently)
	})
	mux.HandleFunc("/c", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("method %s", r.Method)
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("missing"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	port := mustPort(t, srv.URL)
	out := probeHTTP(context.Background(), HTTPInput{
		Target: srv.URL + "/a", Port: port, Version: "1.1", Method: "POST", Body: "ignored-after-redirect",
		Allow4: true, Allow6: true, Timeout: 3 * time.Second, MaxSet: true, MaxRedirects: 5,
	})
	if out.Status != statusOK {
		t.Fatalf("status %s note %s", out.Status, out.Note)
	}
	if strings.Contains(out.Note, "丢包") && !strings.Contains(out.Note, "不是丢包") {
		t.Fatalf("note treats 404 as loss: %s", out.Note)
	}
	if !strings.Contains(out.Note, "不是丢包") || out.Detail["statusCode"] != "404" {
		t.Fatalf("note/detail %+v %s", out.Detail, out.Note)
	}
	if !strings.Contains(out.Detail["finalUrl"], "/c") || !strings.Contains(out.Detail["redirects"], "/a") || !strings.Contains(out.Detail["redirects"], "/b") {
		t.Fatalf("chain %+v", out.Detail)
	}
	if out.Detail["httpVersion"] != "1.1" || !out.HasRtt {
		t.Fatalf("version/rtt %+v", out)
	}
	for _, key := range []string{"dnsMs", "connectMs", "tlsMs", "ttfbMs", "totalMs"} {
		if _, err := strconv.ParseFloat(out.Detail[key], 64); err != nil {
			t.Fatalf("%s: %v", key, err)
		}
	}
}

func TestHTTPPostHeadersAndResolve(t *testing.T) {
	var gotHost, gotBody, gotRef, gotUA, gotCookie string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost = r.Host
		raw, _ := io.ReadAll(r.Body)
		gotBody = string(raw)
		gotRef = r.Referer()
		gotUA = r.UserAgent()
		gotCookie = r.Header.Get("Cookie")
		if r.URL.Path != "/only" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()
	port := mustPort(t, srv.URL)
	out := probeHTTP(context.Background(), HTTPInput{
		Target: "http://example.com/only", Port: port, Version: "1.1", Method: "POST", Body: "hello",
		Referer: "https://from.example/a", UserAgent: "nq-test", Cookies: "a=b",
		Resolve: "cdn.test", Resolver: stubResolver{[]net.IP{net.ParseIP("127.0.0.1")}},
		Allow4: true, Allow6: true, Timeout: 3 * time.Second,
	})
	if out.Status != statusOK || out.Detail["statusCode"] != "201" {
		t.Fatalf("%s %s %+v", out.Status, out.Note, out.Detail)
	}
	if gotHost != "example.com:"+strconv.Itoa(port) {
		t.Fatalf("host %q", gotHost)
	}
	if gotBody != "hello" || gotRef != "https://from.example/a" || gotUA != "nq-test" || gotCookie != "a=b" {
		t.Fatalf("body %q ref %q ua %q cookie %q", gotBody, gotRef, gotUA, gotCookie)
	}
	if out.Detail["address"] != "127.0.0.1" || out.Detail["family"] != "IPv4" {
		t.Fatalf("address %+v", out.Detail)
	}
}

func TestHTTPForceVersionAndSNI(t *testing.T) {
	cert, pool := testCert(t)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || r.TLS.ServerName != "example.com" {
			http.Error(w, "bad sni", http.StatusBadGateway)
			return
		}
		if !strings.HasPrefix(r.Host, "example.com") {
			http.Error(w, "bad host", http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	h2addr, h2close := serveTLS(t, handler, []string{"h2", "http/1.1"}, true, cert)
	defer h2close()
	h1addr, h1close := serveTLS(t, handler, []string{"http/1.1"}, false, cert)
	defer h1close()
	h2port := mustPort(t, "https://"+h2addr)
	h1port := mustPort(t, "https://"+h1addr)

	auto := probeHTTP(context.Background(), tlsInput("https://example.com/path", h2port, "auto", pool))
	if auto.Status != statusOK || auto.Detail["httpVersion"] != "2" || auto.Detail["statusCode"] != "204" {
		t.Fatalf("auto h2: %s %s %+v", auto.Status, auto.Note, auto.Detail)
	}
	forced1 := probeHTTP(context.Background(), tlsInput("https://example.com/path", h2port, "1.1", pool))
	if forced1.Status != statusOK || forced1.Detail["httpVersion"] != "1.1" {
		t.Fatalf("force 1.1: %s %s %+v", forced1.Status, forced1.Note, forced1.Detail)
	}
	forced2 := probeHTTP(context.Background(), tlsInput("https://example.com/path", h1port, "2", pool))
	if forced2.Status == statusOK || !strings.Contains(forced2.Note, "HTTP/2") || strings.Contains(forced2.Note, "降级到") {
		t.Fatalf("force 2 should fail closed: %s %s", forced2.Status, forced2.Note)
	}
	plain := probeHTTP(context.Background(), HTTPInput{
		Target: "http://127.0.0.1/x", Port: 9, Version: "3", Allow4: true, Allow6: true, Timeout: time.Second,
	})
	if plain.Status == statusOK || !strings.Contains(plain.Note, "需要 HTTPS") {
		t.Fatalf("cleartext h3: %s %s", plain.Status, plain.Note)
	}
}

func TestHTTP3(t *testing.T) {
	cert, pool := testCert(t)
	udp, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	h3 := &http3.Server{
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.TLS == nil || r.TLS.ServerName != "example.com" {
				http.Error(w, "bad sni", http.StatusBadGateway)
				return
			}
			if !strings.HasPrefix(r.Host, "example.com") {
				http.Error(w, "bad host "+r.Host, http.StatusBadGateway)
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, "h3")
		}),
	}
	go h3.Serve(udp)
	defer h3.Close()
	port := udp.LocalAddr().(*net.UDPAddr).Port
	out := probeHTTP(context.Background(), tlsInput("https://example.com/h3", port, "3", pool))
	if out.Status != statusOK || out.Detail["httpVersion"] != "3" || out.Detail["statusCode"] != "200" {
		t.Fatalf("h3: %s %s %+v", out.Status, out.Note, out.Detail)
	}
	if out.Detail["address"] != "127.0.0.1" {
		t.Fatalf("address %+v", out.Detail)
	}
	tcpAddr, closeTCP := serveTLS(t, http.NotFoundHandler(), []string{"h2", "http/1.1"}, true, cert)
	defer closeTCP()
	failed := probeHTTP(context.Background(), tlsInput("https://example.com/nope", mustPort(t, "https://"+tcpAddr), "3", pool))
	if failed.Status == statusOK || strings.Contains(failed.Note, "降到") {
		t.Fatalf("h3 against tcp: %s %s", failed.Status, failed.Note)
	}
}

func TestHTTPFamilyRefusal(t *testing.T) {
	out := probeHTTP(context.Background(), HTTPInput{
		Target: "127.0.0.1", Port: 80, Allow4: false, Allow6: true, Timeout: time.Second,
	})
	if out.Status == statusOK || !strings.Contains(out.Note, "IPv4") {
		t.Fatalf("%s %s", out.Status, out.Note)
	}
	both := probeHTTP(context.Background(), HTTPInput{
		Target: "example.com", Port: 443, Allow4: false, Allow6: false, Timeout: time.Second,
	})
	if !strings.Contains(both.Note, "都已关闭") {
		t.Fatal(both.Note)
	}
}

func TestNodeHonorsFamilyAndHTTP(t *testing.T) {
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer page.Close()
	port := mustPort(t, page.URL)
	node := newNode("", true, nil, testLimits())
	node.Resolver = stubResolver{[]net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}}
	ts := httptest.NewServer(node.Handler())
	defer ts.Close()

	bad := postJSON(t, ts.URL+"/v1/jobs", `{"target":"127.0.0.1","port":1,"profile":"tcp-connect","intervalMs":200,"timeoutMs":300,"durationSec":1,"allowIPv4":false,"allowIPv6":true}`)
	if bad.StatusCode != http.StatusBadRequest {
		t.Fatalf("literal v4 status %d", bad.StatusCode)
	}
	badBody, _ := io.ReadAll(bad.Body)
	bad.Body.Close()
	if !strings.Contains(string(badBody), "IPv4") {
		t.Fatalf("body %s", badBody)
	}
	both := postJSON(t, ts.URL+"/v1/jobs", `{"target":"127.0.0.1","port":1,"profile":"tcp-connect","intervalMs":200,"timeoutMs":300,"durationSec":1,"allowIPv4":false,"allowIPv6":false}`)
	both.Body.Close()
	if both.StatusCode != http.StatusBadRequest {
		t.Fatalf("both off %d", both.StatusCode)
	}

	created := postJSON(t, ts.URL+"/v1/jobs", `{"target":"example.test","port":1,"profile":"tcp-connect","intervalMs":200,"timeoutMs":300,"durationSec":1,"allowIPv4":false,"allowIPv6":true}`)
	defer created.Body.Close()
	if created.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(created.Body)
		t.Fatalf("family filter create %d %s", created.StatusCode, raw)
	}
	var createdBody map[string]any
	if err := json.NewDecoder(created.Body).Decode(&createdBody); err != nil {
		t.Fatal(err)
	}
	resolved, _ := createdBody["resolved"].([]any)
	if len(resolved) != 1 {
		t.Fatalf("resolved %+v", createdBody["resolved"])
	}
	first, _ := resolved[0].(map[string]any)
	if first["address"] != "::1" || first["family"] != "IPv6" {
		t.Fatalf("resolved %+v", first)
	}

	httpJob := postJSON(t, ts.URL+"/v1/jobs", `{"target":"`+page.URL+`/","port":`+strconv.Itoa(port)+`,"profile":"http","intervalMs":200,"timeoutMs":1500,"durationSec":2,"http":{"version":"1.1","method":"GET","maxRedirects":5}}`)
	defer httpJob.Body.Close()
	if httpJob.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(httpJob.Body)
		t.Fatalf("http create %d %s", httpJob.StatusCode, raw)
	}
	var job map[string]any
	if err := json.NewDecoder(httpJob.Body).Decode(&job); err != nil {
		t.Fatal(err)
	}
	id, _ := job["jobId"].(string)
	sample := readSampleURL(t, ts.URL+"/v1/jobs/"+id+"/stream")
	if sample["status"] != statusOK {
		t.Fatalf("sample %+v", sample)
	}
	detail, _ := sample["detail"].(map[string]any)
	if detail["statusCode"] != "502" {
		t.Fatalf("detail %+v", detail)
	}
	note, _ := sample["note"].(string)
	if !strings.Contains(note, "不是丢包") {
		t.Fatalf("note %s", note)
	}
}

func TestHelperSpeaksHTTPEngine(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	port := mustPort(t, srv.URL)
	var in bytes.Buffer
	req, _ := json.Marshal(map[string]any{
		"profile": "http", "target": srv.URL + "/", "port": port, "timeoutMs": 2000,
		"allowIPv4": true, "allowIPv6": false,
		"http": map[string]any{"version": "1.1", "method": "GET"},
	})
	in.Write(req)
	in.WriteByte('\n')
	var out bytes.Buffer
	if err := runHelper(&in, &out); err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(&out)
	if !sc.Scan() {
		t.Fatal("no output")
	}
	var body map[string]any
	if err := json.Unmarshal(sc.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != statusOK {
		t.Fatalf("%+v", body)
	}
	detail, _ := body["detail"].(map[string]any)
	if detail["httpVersion"] != "1.1" || detail["statusCode"] != "204" {
		t.Fatalf("%+v", detail)
	}
}

func TestBuildHTTPURLDefaults(t *testing.T) {
	cases := []struct {
		target string
		wire   int
		scheme string
		host   string
		port   string
		path   string
		query  string
	}{
		{"example.com", 0, "http", "example.com", "80", "/", ""},
		{"example.com", 80, "http", "example.com", "80", "/", ""},
		{"example.com", 443, "http", "example.com", "443", "/", ""},
		{"rxsend.cn", 0, "http", "rxsend.cn", "80", "/", ""},
		{"https://www.cause-by-siky.top:2025/", 80, "https", "www.cause-by-siky.top", "2025", "/", ""},
		{"https://www.cause-by-siky.top:2025/a?q=1", 9, "https", "www.cause-by-siky.top", "2025", "/a", "q=1"},
		{"http://example.com/path", 0, "http", "example.com", "80", "/path", ""},
		{"https://example.com/path", 0, "https", "example.com", "443", "/path", ""},
		{"example.com:8080/a", 443, "http", "example.com", "8080", "/a", ""},
		{"example.com/path?q=1", 0, "http", "example.com", "80", "/path", "q=1"},
		{"[2001:db8::1]", 0, "http", "2001:db8::1", "80", "/", ""},
		{"[2001:db8::1]:8080/a", 80, "http", "2001:db8::1", "8080", "/a", ""},
		{"2001:db8::1", 0, "http", "2001:db8::1", "80", "/", ""},
	}
	for _, tc := range cases {
		u, err := buildHTTPURL(tc.target, tc.wire)
		if err != nil {
			t.Fatalf("%s port %d: %v", tc.target, tc.wire, err)
		}
		if u.Scheme != tc.scheme || u.Hostname() != tc.host || u.Port() != tc.port || u.Path != tc.path || u.RawQuery != tc.query {
			t.Fatalf("%s port %d -> %s", tc.target, tc.wire, u.String())
		}
	}
	if _, err := buildHTTPURL("", 80); err == nil || !strings.Contains(err.Error(), "目标地址") {
		t.Fatal(err)
	}
	if _, err := buildHTTPURL("ftp://example.com", 80); err == nil || !strings.Contains(err.Error(), "http/https") {
		t.Fatal(err)
	}
	if _, err := buildHTTPURL("https://example.com:99999/", 80); err == nil || !strings.Contains(err.Error(), "端口") {
		t.Fatal(err)
	}
	if _, err := buildHTTPURL("example.com", 70000); err == nil || !strings.Contains(err.Error(), "端口") {
		t.Fatal(err)
	}
}

func TestHTTPExplicitURLPortIgnoresField(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	out := probeHTTP(context.Background(), HTTPInput{
		Target: srv.URL + "/health", Port: 1, Version: "1.1",
		Allow4: true, Allow6: true, Timeout: 3 * time.Second,
	})
	if out.Status != statusOK || out.Detail["statusCode"] != "204" {
		t.Fatalf("url port should win: %s %s %+v", out.Status, out.Note, out.Detail)
	}
	omitted := probeHTTP(context.Background(), HTTPInput{
		Target: srv.URL + "/health", Port: 0, Version: "1.1",
		Allow4: true, Allow6: true, Timeout: 3 * time.Second,
	})
	if omitted.Status != statusOK || omitted.Detail["statusCode"] != "204" {
		t.Fatalf("omitted port: %s %s %+v", omitted.Status, omitted.Note, omitted.Detail)
	}
}

func TestHTTPJobAcceptsURLWithoutPortField(t *testing.T) {
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	}))
	defer page.Close()
	node := newNode("", true, nil, testLimits())
	ts := httptest.NewServer(node.Handler())
	defer ts.Close()
	created := postJSON(t, ts.URL+"/v1/jobs", `{"target":"`+page.URL+`/","port":0,"profile":"http","intervalMs":200,"timeoutMs":1500,"durationSec":2,"http":{"version":"1.1","method":"GET"}}`)
	defer created.Body.Close()
	if created.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(created.Body)
		t.Fatalf("http without port field %d %s", created.StatusCode, raw)
	}
	var job map[string]any
	if err := json.NewDecoder(created.Body).Decode(&job); err != nil {
		t.Fatal(err)
	}
	id, _ := job["jobId"].(string)
	sample := readSampleURL(t, ts.URL+"/v1/jobs/"+id+"/stream")
	if sample["status"] != statusOK {
		t.Fatalf("sample %+v", sample)
	}
	detail, _ := sample["detail"].(map[string]any)
	if detail["statusCode"] != "202" {
		t.Fatalf("detail %+v", detail)
	}
	tcp := postJSON(t, ts.URL+"/v1/jobs", `{"target":"127.0.0.1","port":0,"profile":"tcp-connect","intervalMs":200,"timeoutMs":300,"durationSec":1}`)
	defer tcp.Body.Close()
	if tcp.StatusCode != http.StatusBadRequest {
		t.Fatalf("tcp still requires a port, got %d", tcp.StatusCode)
	}
}

func tlsInput(target string, port int, version string, pool *x509.CertPool) HTTPInput {
	return HTTPInput{
		Target: target, Port: port, Version: version, Resolve: "127.0.0.1",
		Allow4: true, Allow6: true, Timeout: 4 * time.Second, Roots: pool,
	}
}

func testCert(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"example.com"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pool
}

func serveTLS(t *testing.T, handler http.Handler, protos []string, h2 bool, cert tls.Certificate) (string, func()) {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   protos,
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	if !h2 {
		srv.TLSNextProto = map[string]func(*http.Server, *tls.Conn, http.Handler){}
	}
	go srv.Serve(ln)
	return ln.Addr().String(), func() { _ = srv.Close() }
}

func mustPort(t *testing.T, raw string) int {
	t.Helper()
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	return port
}

func postJSON(t *testing.T, url, body string) *http.Response {
	t.Helper()
	res, err := http.Post(url, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func readSampleURL(t *testing.T, rawURL string) map[string]any {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 5 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	sc := bufio.NewScanner(res.Body)
	var data string
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "data: ") {
			data = strings.TrimPrefix(line, "data: ")
		}
		if line == "" && data != "" && data != "{}" {
			var msg map[string]any
			if err := json.Unmarshal([]byte(data), &msg); err != nil {
				t.Fatal(err)
			}
			if msg["status"] != "" && msg["status"] != "pending" {
				return msg
			}
			data = ""
		}
	}
	t.Fatal("no sample")
	return nil
}
