// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

const httpBodyCap = 32 << 10

// HTTPInput is one HTTP probe. The same function serves the node and the
// local helper, so desktop, Android and remote nodes share this engine.
type HTTPInput struct {
	Target       string
	Port         int
	Version      string
	Resolve      string
	Method       string
	Body         string
	Referer      string
	UserAgent    string
	Cookies      string
	MaxRedirects int
	MaxSet       bool
	Timeout      time.Duration
	Allow4       bool
	Allow6       bool
	CheckSafety  bool
	AllowPrivate bool
	Extra        []*net.IPNet
	Resolver     resolver
	Insecure     bool
	Roots        *x509.CertPool
	Preferred    net.IP
}

func probeHTTP(ctx context.Context, in HTTPInput) Outcome {
	started := time.Now()
	version, err := normalizeHTTPVersion(in.Version)
	if err != nil {
		return httpFail(statusError, err.Error())
	}
	method := strings.ToUpper(strings.TrimSpace(in.Method))
	if method == "" {
		method = http.MethodGet
	}
	if method != http.MethodGet && method != http.MethodPost {
		return httpFail(statusError, "HTTP 方法只支持 GET 和 POST")
	}
	if method != http.MethodPost {
		in.Body = ""
	}
	if len(in.Body) > 64<<10 || len(in.Referer) > 4096 || len(in.UserAgent) > 4096 || len(in.Cookies) > 4096 {
		return httpFail(statusError, "HTTP 选项超过长度限制")
	}
	page, err := buildHTTPURL(in.Target, in.Port)
	if err != nil {
		return httpFail(statusError, err.Error())
	}
	if (version == "2" || version == "3") && page.Scheme != "https" {
		name := "HTTP/2"
		if version == "3" {
			name = "HTTP/3"
		}
		return httpFail(statusError, "强制 "+name+" 需要 HTTPS，不会降级")
	}
	maxRedirect := in.MaxRedirects
	if !in.MaxSet && maxRedirect == 0 {
		maxRedirect = 5
	}
	if maxRedirect < 0 || maxRedirect > 20 {
		return httpFail(statusError, "跳转次数需要在 0 到 20 之间")
	}
	if in.Timeout <= 0 {
		in.Timeout = 1500 * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(ctx, in.Timeout)
	defer cancel()

	originHost := page.Hostname()
	var chain []string
	var dnsSum, connSum, tlsSum time.Duration
	var used net.IP
	var gotVersion string
	var ttfb time.Duration
	current := page
	currentMethod := method
	currentBody := in.Body
	seen := map[string]int{}

	for followed := 0; ; followed++ {
		if seen[current.String()] > 2 {
			return httpDone(started, dnsSum, connSum, tlsSum, ttfb, used, gotVersion, 0, current.String(), chain, statusError, "跳转出现了循环")
		}
		seen[current.String()]++
		resp, hop, err := in.do(ctx, current, currentMethod, currentBody, version, originHost)
		dnsSum += hop.dns
		connSum += hop.connect
		tlsSum += hop.tls
		if hop.addr != nil {
			used = hop.addr
		}
		if hop.version != "" {
			gotVersion = hop.version
		}
		if err != nil {
			if ctx.Err() != nil && !errors.Is(err, errForbiddenTarget) {
				if fe, ok := asFamily(err); ok {
					return httpDone(started, dnsSum, connSum, tlsSum, ttfb, used, gotVersion, 0, current.String(), chain, statusError, fe.Error())
				}
			}
			return httpDone(started, dnsSum, connSum, tlsSum, ttfb, used, gotVersion, 0, current.String(), chain, hop.status, hop.note)
		}
		if hop.ttfb > 0 && ttfb == 0 {
			ttfb = time.Since(started)
		}
		if hop.ttfb > 0 {
			ttfb = time.Since(started)
		}
		code := resp.StatusCode
		finalURL := current.String()
		if resp.Request != nil && resp.Request.URL != nil {
			finalURL = resp.Request.URL.String()
		}
		chain = append(chain, strconv.Itoa(code)+" "+finalURL)
		loc := resp.Header.Get("Location")
		redirect := code >= 300 && code < 400 && loc != ""
		if !redirect {
			_, _ = io.CopyN(io.Discard, resp.Body, httpBodyCap)
			_ = resp.Body.Close()
			note := fmt.Sprintf("HTTP %d", code)
			if code >= 400 {
				note += "。这是服务器返回的状态，不是丢包"
			}
			out := httpDone(started, dnsSum, connSum, tlsSum, ttfb, used, gotVersion, code, finalURL, chain, statusOK, note)
			if hop.fallback != "" {
				out.Detail["fallback"] = hop.fallback
			}
			out.HasRtt = true
			out.Rtt = time.Since(started)
			return out
		}
		_ = resp.Body.Close()
		if followed >= maxRedirect {
			return httpDone(started, dnsSum, connSum, tlsSum, ttfb, used, gotVersion, code, finalURL, chain, statusError, fmt.Sprintf("超过了最多 %d 次跳转", maxRedirect))
		}
		next, err := current.Parse(loc)
		if err != nil || next.Host == "" || (next.Scheme != "http" && next.Scheme != "https") {
			return httpDone(started, dnsSum, connSum, tlsSum, ttfb, used, gotVersion, code, finalURL, chain, statusError, "跳转地址无效")
		}
		current = next
		if code == http.StatusMovedPermanently || code == http.StatusFound || code == http.StatusSeeOther {
			currentMethod = http.MethodGet
			currentBody = ""
		}
	}
}

type httpHop struct {
	dns     time.Duration
	connect time.Duration
	tls     time.Duration
	ttfb     time.Duration
	addr     net.IP
	version  string
	status   string
	note     string
	fallback string
}

func (in HTTPInput) do(ctx context.Context, page *url.URL, method, body, version, originHost string) (*http.Response, httpHop, error) {
	connectHost := page.Hostname()
	if strings.EqualFold(connectHost, originHost) && strings.TrimSpace(in.Resolve) != "" {
		connectHost = strings.TrimSpace(in.Resolve)
	}
	ips, dnsDur, err := in.lookup(ctx, connectHost)
	hop := httpHop{dns: dnsDur, status: statusError, note: "连接失败"}
	if err != nil {
		hop.status, hop.note = classifyHTTPLookup(err, version)
		return nil, hop, err
	}
	ips = preferIP(ips, in.Preferred)
	var last error
	var skipped []string
	for _, ip := range ips {
		resp, one, err := in.exchange(ctx, page, method, body, version, ip)
		one.dns = dnsDur
		if err == nil {
			if len(skipped) > 0 {
				one.fallback = "已尝试 " + strings.Join(skipped, "、") + "，随后改用 " + familyOf(ip) + " " + ip.String()
			}
			return resp, one, nil
		}
		last = err
		hop = one
		hop.dns = dnsDur
		if !retryHTTP(err) {
			break
		}
		skipped = append(skipped, familyOf(ip)+" "+ip.String())
	}
	if last == nil {
		last = errors.New("连接失败")
	}
	if hop.note == "" || hop.note == "skipped" {
		hop.status, hop.note = classifyHTTPDial(last, version)
	}
	if len(skipped) > 0 && hop.note != "" {
		hop.note = "已尝试 " + strings.Join(skipped, "、") + "。" + hop.note
	}
	return nil, hop, last
}

func (in HTTPInput) exchange(ctx context.Context, page *url.URL, method, body, version string, ip net.IP) (*http.Response, httpHop, error) {
	hop := httpHop{addr: ip, status: statusError, note: "连接失败"}
	req, err := http.NewRequestWithContext(ctx, method, page.String(), strings.NewReader(body))
	if err != nil {
		hop.note = "无法构造 HTTP 请求"
		return nil, hop, err
	}
	if body != "" {
		req.ContentLength = int64(len(body))
		req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	}
	if in.Referer != "" {
		req.Header.Set("Referer", in.Referer)
	}
	if in.UserAgent != "" {
		req.Header.Set("User-Agent", in.UserAgent)
	}
	if in.Cookies != "" {
		req.Header.Set("Cookie", in.Cookies)
	}
	var connectDur, tlsDur time.Duration
	var connectStart, tlsStart time.Time
	trace := &httptrace.ClientTrace{
		ConnectStart: func(string, string) { connectStart = time.Now() },
		ConnectDone: func(string, string, error) {
			if !connectStart.IsZero() {
				connectDur = time.Since(connectStart)
			}
		},
		TLSHandshakeStart: func() { tlsStart = time.Now() },
		TLSHandshakeDone: func(tls.ConnectionState, error) {
			if !tlsStart.IsZero() {
				tlsDur = time.Since(tlsStart)
			}
		},
		GotFirstResponseByte: func() { hop.ttfb = time.Nanosecond },
	}
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), trace))

	var resp *http.Response
	switch version {
	case "3":
		t0 := time.Now()
		resp, err = in.roundTripH3(req, ip)
		elapsed := time.Since(t0)
		// QUIC finishes the UDP association and the TLS handshake together.
		connectDur = elapsed
		tlsDur = elapsed
	default:
		resp, err = in.roundTripTCP(req, ip, version)
	}
	hop.connect = connectDur
	hop.tls = tlsDur
	if err != nil {
		hop.status, hop.note = classifyHTTPDial(err, version)
		return nil, hop, err
	}
	got := canonicalProto(resp.Proto)
	if version == "1.1" && got != "1.1" {
		_ = resp.Body.Close()
		hop.note = "服务器没有使用 HTTP/1.1，已按设置失败，没有降级"
		return nil, hop, errors.New(hop.note)
	}
	if version == "2" && got != "2" {
		_ = resp.Body.Close()
		hop.note = "服务器不支持 HTTP/2，已按设置失败，没有降级"
		return nil, hop, errors.New(hop.note)
	}
	if version == "3" && got != "3" {
		_ = resp.Body.Close()
		hop.note = "服务器不支持 HTTP/3，已按设置失败，没有降级"
		return nil, hop, errors.New(hop.note)
	}
	hop.version = got
	hop.status = statusOK
	hop.note = ""
	return resp, hop, nil
}

func (in HTTPInput) roundTripTCP(req *http.Request, ip net.IP, version string) (*http.Response, error) {
	port := req.URL.Port()
	if port == "" {
		if req.URL.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	dialAddr := net.JoinHostPort(ip.String(), port)
	tlsConf := &tls.Config{
		ServerName:         req.URL.Hostname(),
		InsecureSkipVerify: in.Insecure,
		RootCAs:            in.Roots,
		MinVersion:         tls.VersionTLS12,
	}
	switch version {
	case "1.1":
		tlsConf.NextProtos = []string{"http/1.1"}
	case "2":
		tlsConf.NextProtos = []string{"h2"}
	default:
		tlsConf.NextProtos = []string{"h2", "http/1.1"}
	}
	transport := &http.Transport{
		Proxy:             nil,
		ForceAttemptHTTP2: version != "1.1",
		TLSClientConfig:   tlsConf,
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{}
			use := "tcp4"
			if ip.To4() == nil {
				use = "tcp6"
			}
			return d.DialContext(ctx, use, dialAddr)
		},
	}
	if version == "1.1" {
		transport.ForceAttemptHTTP2 = false
		transport.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return client.Do(req)
}

func (in HTTPInput) roundTripH3(req *http.Request, ip net.IP) (*http.Response, error) {
	port := req.URL.Port()
	if port == "" {
		port = "443"
	}
	addr := net.JoinHostPort(ip.String(), port)
	tlsConf := &tls.Config{
		ServerName:         req.URL.Hostname(),
		InsecureSkipVerify: in.Insecure,
		RootCAs:            in.Roots,
		NextProtos:         []string{http3.NextProtoH3},
		MinVersion:         tls.VersionTLS12,
	}
	rt := &http3.Transport{
		TLSClientConfig: tlsConf,
		Dial: func(ctx context.Context, _ string, tlsCfg *tls.Config, cfg *quic.Config) (quic.EarlyConnection, error) {
			if cfg == nil {
				cfg = &quic.Config{}
			} else {
				cfg = cfg.Clone()
			}
			if cfg.HandshakeIdleTimeout == 0 || cfg.HandshakeIdleTimeout > time.Second {
				cfg.HandshakeIdleTimeout = time.Second
			}
			return quic.DialAddrEarly(ctx, addr, tlsCfg, cfg)
		},
	}
	defer rt.Close()
	client := &http.Client{
		Transport: rt,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return client.Do(req)
}

func (in HTTPInput) lookup(ctx context.Context, host string) ([]net.IP, time.Duration, error) {
	host = strings.TrimSpace(host)
	host = strings.Trim(host, "[]")
	if host == "" {
		return nil, 0, errors.New("empty host")
	}
	if !in.Allow4 && !in.Allow6 {
		return nil, 0, familyMessage("IPv4 和 IPv6 都已关闭，无法开始探测")
	}
	if ip := net.ParseIP(host); ip != nil {
		filtered, err := filterFamily(host, []net.IP{ip}, in.Allow4, in.Allow6)
		if err != nil {
			return nil, 0, err
		}
		if in.CheckSafety && !ipAllowed(ip, in.AllowPrivate, in.Extra) {
			return nil, 0, fmt.Errorf("%w: %s", errForbiddenTarget, ip.String())
		}
		return filtered, 0, nil
	}
	start := time.Now()
	var ips []net.IP
	var err error
	if in.CheckSafety {
		ips, err = resolveTargets(ctx, in.Resolver, host, in.AllowPrivate, in.Extra)
	} else {
		ips, err = lookupPlain(ctx, in.Resolver, host)
	}
	elapsed := time.Since(start)
	if err != nil {
		return nil, elapsed, err
	}
	filtered, err := filterFamily(host, ips, in.Allow4, in.Allow6)
	if err != nil {
		return nil, elapsed, err
	}
	return filtered, elapsed, nil
}

func lookupPlain(ctx context.Context, r resolver, host string) ([]net.IP, error) {
	if r == nil {
		r = net.DefaultResolver
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	addrs, err := r.LookupIPAddr(lookupCtx, host)
	if err != nil {
		return nil, err
	}
	if len(addrs) == 0 {
		return nil, &net.DNSError{Err: "no addresses", Name: host, IsNotFound: true}
	}
	out := make([]net.IP, 0, len(addrs))
	for _, addr := range addrs {
		out = append(out, addr.IP)
	}
	return out, nil
}

func buildHTTPURL(target string, port int) (*url.URL, error) {
	target = strings.TrimSpace(target)
	if target == "" {
		return nil, errors.New("请填写目标地址")
	}
	raw := target
	if !strings.Contains(raw, "://") {
		scheme := "https"
		if port == 80 {
			scheme = "http"
		}
		hostpart := raw
		path := ""
		if i := strings.Index(raw, "/"); i >= 0 {
			hostpart, path = raw[:i], raw[i:]
		}
		if strings.Count(hostpart, ":") >= 2 && !strings.HasPrefix(hostpart, "[") {
			hostpart = "[" + hostpart + "]"
		}
		raw = scheme + "://" + hostpart + path
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, errors.New("HTTP 目标需要是主机名或 http/https 网址")
	}
	if u.Port() == "" {
		if port < 1 || port > 65535 {
			return nil, errors.New("端口需要在 1 到 65535 之间")
		}
		u.Host = net.JoinHostPort(u.Hostname(), strconv.Itoa(port))
	}
	if u.Path == "" {
		u.Path = "/"
	}
	return u, nil
}

func normalizeHTTPVersion(v string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "", "auto":
		return "auto", nil
	case "1.1", "http/1.1":
		return "1.1", nil
	case "2", "http/2":
		return "2", nil
	case "3", "http/3":
		return "3", nil
	default:
		return "", errors.New("HTTP 版本需要是自动、1.1、2 或 3")
	}
}

func canonicalProto(proto string) string {
	p := strings.ToUpper(strings.TrimSpace(proto))
	switch {
	case strings.Contains(p, "3"):
		return "3"
	case strings.Contains(p, "2"):
		return "2"
	case strings.Contains(p, "1.1"):
		return "1.1"
	case strings.Contains(p, "1.0"):
		return "1.0"
	default:
		return p
	}
}

func classifyHTTPLookup(err error, version string) (string, string) {
	if fe, ok := asFamily(err); ok {
		return statusError, fe.Error()
	}
	if errors.Is(err, errForbiddenTarget) {
		return statusError, "远程节点默认不探测本机、内网、链路本地或云元数据地址。管理员开放局域网后才能测这些地址"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return statusDNS, "域名无法解析"
	}
	return classifyHTTPDial(err, version)
}

func classifyHTTPDial(err error, version string) (string, string) {
	if err == nil {
		return statusError, "连接失败"
	}
	if fe, ok := asFamily(err); ok {
		return statusError, fe.Error()
	}
	if errors.Is(err, errForbiddenTarget) {
		return statusError, "远程节点默认不探测本机、内网、链路本地或云元数据地址。管理员开放局域网后才能测这些地址"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return statusDNS, "域名无法解析"
	}
	msg := err.Error()
	if strings.Contains(msg, "没有使用 HTTP/1.1") || strings.Contains(msg, "不支持 HTTP/2") || strings.Contains(msg, "不支持 HTTP/3") {
		return statusError, msg
	}
	out := classifyDial(err)
	if out.Note == "" {
		out.Note = "连接失败"
	}
	if version == "2" || version == "3" {
		if out.Status == statusTimeout || out.Status == statusRefused || out.Status == statusDNS {
			return out.Status, out.Note
		}
		name := "HTTP/2"
		if version == "3" {
			name = "HTTP/3"
		}
		return statusError, "服务器不支持 " + name + "，已按设置失败，没有降级"
	}
	return out.Status, out.Note
}

func retryHTTP(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return false
	}
	if _, ok := asFamily(err); ok {
		return false
	}
	if errors.Is(err, errForbiddenTarget) {
		return false
	}
	var dnsErr *net.DNSError
	return !errors.As(err, &dnsErr)
}

func httpFail(status, note string) Outcome {
	return Outcome{Status: status, Kind: kindQuery, Note: note}
}

func httpDone(started time.Time, dns, conn, tls, ttfb time.Duration, ip net.IP, version string, code int, final string, chain []string, status, note string) Outcome {
	detail := map[string]string{}
	putMs(detail, "dnsMs", dns)
	putMs(detail, "connectMs", conn)
	putMs(detail, "tlsMs", tls)
	putMs(detail, "ttfbMs", ttfb)
	putMs(detail, "totalMs", time.Since(started))
	if version != "" {
		detail["httpVersion"] = version
	}
	if code > 0 {
		detail["statusCode"] = strconv.Itoa(code)
	}
	if final != "" {
		detail["finalUrl"] = final
	}
	if len(chain) > 0 {
		detail["redirects"] = strings.Join(chain, " -> ")
	}
	out := Outcome{Status: status, Kind: kindQuery, Note: note, Detail: detail}
	if ip != nil {
		out = stampIP(out, ip)
	}
	return out
}

type httpProbe struct {
	spec jobSpec
}

func (p *httpProbe) Close() error { return nil }

func (p *httpProbe) Probe(ctx context.Context) Outcome {
	in := p.spec.HTTP
	in.Preferred = p.spec.dialIP()
	out := probeHTTP(ctx, in)
	if p.spec.state != nil {
		p.spec.state.used = nil
		if out.Status == statusOK {
			if ip := net.ParseIP(out.Detail["address"]); ip != nil {
				p.spec.state.used = append(net.IP(nil), ip...)
			}
		}
	}
	return out
}

func putMs(detail map[string]string, key string, d time.Duration) {
	if d < 0 {
		d = 0
	}
	detail[key] = strconv.FormatFloat(float64(d)/float64(time.Millisecond), 'f', 3, 64)
}
