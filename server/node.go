package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type jobSpec struct {
	Host       string
	Port       int
	Profile    string
	IP         net.IP
	Interval   time.Duration
	Timeout    time.Duration
	Duration   time.Duration
	PacketSize int
	Echo       [tokenLen]byte
	DNSName    string
	Payload    []byte
	Expect     []byte
}

type Limits struct {
	MaxJobs        int
	MaxDuration    time.Duration
	MinInterval    time.Duration
	MaxProbePerSec int
	MaxBytesPerSec int
	MaxPacket      int
}

func defaultLimits() Limits {
	return Limits{
		MaxJobs:        4,
		MaxDuration:    120 * time.Second,
		MinInterval:    200 * time.Millisecond,
		MaxProbePerSec: 20,
		MaxBytesPerSec: 256 * 1024,
		MaxPacket:      1400,
	}
}

type sampleMsg struct {
	Seq      int               `json:"seq"`
	Status   string            `json:"status"`
	Kind     string            `json:"kind"`
	RttMs    *float64          `json:"rttMs,omitempty"`
	JitterMs *float64          `json:"jitterMs,omitempty"`
	Note     string            `json:"note,omitempty"`
	Detail   map[string]string `json:"detail,omitempty"`
	Summary  summaryMsg        `json:"summary"`
}

type Node struct {
	Token        string
	AllowPrivate bool
	ExtraNets    []*net.IPNet
	Limits       Limits
	Resolver     resolver

	mu   sync.Mutex
	jobs map[string]*probeJob
	sem  chan struct{}
	pace *paced
}

func newNode(token string, allowPrivate bool, extra []*net.IPNet, limits Limits) *Node {
	if limits.MaxJobs <= 0 {
		limits = defaultLimits()
	}
	n := &Node{
		Token:        token,
		AllowPrivate: allowPrivate,
		ExtraNets:    extra,
		Limits:       limits,
		jobs:         map[string]*probeJob{},
		sem:          make(chan struct{}, limits.MaxJobs),
		pace:         newPaced(limits.MaxProbePerSec, limits.MaxBytesPerSec),
	}
	go n.reap()
	return n
}

func (n *Node) Public() bool { return n.Token == "" }

func (n *Node) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", n.info)
	mux.HandleFunc("POST /v1/jobs", n.auth(n.create))
	mux.HandleFunc("GET /v1/jobs/{id}", n.auth(n.snapshot))
	mux.HandleFunc("GET /v1/jobs/{id}/stream", n.auth(n.stream))
	mux.HandleFunc("DELETE /v1/jobs/{id}", n.auth(n.remove))
	return mux
}

func (n *Node) info(w http.ResponseWriter, _ *http.Request) {
	vis := "private"
	if n.Public() {
		vis = "public"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"visibility":   vis,
		"authRequired": !n.Public(),
		"profiles": []string{
			"nq-tcp", "nq-udp", "tcp-connect", "udp-generic", "dns",
			"minecraft-java", "minecraft-bedrock", "custom-udp",
		},
		"limits": map[string]int{
			"maxJobs":        n.Limits.MaxJobs,
			"maxDurationSec": int(n.Limits.MaxDuration / time.Second),
			"minIntervalMs":  int(n.Limits.MinInterval / time.Millisecond),
			"maxPacketBytes": n.Limits.MaxPacket,
			"maxBytesPerSec": n.Limits.MaxBytesPerSec,
			"maxProbePerSec": n.Limits.MaxProbePerSec,
		},
	})
}

func (n *Node) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if n.Token == "" {
			next(w, r)
			return
		}
		got := bearer(r.Header.Get("Authorization"))
		if got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(n.Token)) != 1 {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "节点口令不正确或未提供")
			return
		}
		next(w, r)
	}
}

type createReq struct {
	Target      string `json:"target"`
	Port        int    `json:"port"`
	Profile     string `json:"profile"`
	IntervalMs  int    `json:"intervalMs"`
	TimeoutMs   int    `json:"timeoutMs"`
	DurationSec int    `json:"durationSec"`
	PacketSize  int    `json:"packetSize"`
	EchoToken   string `json:"echoToken"`
	DNSName     string `json:"dnsName"`
	PayloadHex  string `json:"payloadHex"`
	ExpectHex   string `json:"expectHex"`
}

func (n *Node) create(w http.ResponseWriter, r *http.Request) {
	var req createReq
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<16))
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "请求内容无法解析")
		return
	}
	spec, err := n.prepare(r.Context(), req)
	if err != nil {
		var ae *apiError
		if errors.As(err, &ae) {
			writeErr(w, ae.status, ae.code, ae.msg)
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_request", "无法创建探测任务")
		return
	}
	select {
	case n.sem <- struct{}{}:
	default:
		writeErr(w, http.StatusTooManyRequests, "busy", "节点同时探测的任务已达上限")
		return
	}
	job, err := n.start(spec)
	if err != nil {
		<-n.sem
		writeErr(w, http.StatusInternalServerError, "error", "任务没有启动")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"jobId":      job.id,
		"expiresAt":  job.expires.UTC().Format(time.RFC3339),
		"visibility": map[bool]string{true: "public", false: "private"}[n.Public()],
	})
}

func (n *Node) prepare(ctx context.Context, req createReq) (jobSpec, error) {
	switch req.Profile {
	case "nq-tcp", "nq-udp", "tcp-connect", "udp-generic", "dns", "minecraft-java", "minecraft-bedrock", "custom-udp":
	default:
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_profile", "不支持的探测类型"}
	}
	if req.Port < 1 || req.Port > 65535 {
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_port", "端口需要在 1 到 65535 之间"}
	}
	interval := time.Duration(req.IntervalMs) * time.Millisecond
	if req.IntervalMs == 0 {
		interval = 500 * time.Millisecond
	}
	if interval < n.Limits.MinInterval || interval > 30*time.Second {
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_interval", "发送间隔超出节点允许的范围"}
	}
	timeout := time.Duration(req.TimeoutMs) * time.Millisecond
	if req.TimeoutMs == 0 {
		timeout = 1500 * time.Millisecond
	}
	if timeout < 100*time.Millisecond || timeout > 15*time.Second {
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_timeout", "超时超出节点允许的范围"}
	}
	duration := time.Duration(req.DurationSec) * time.Second
	if req.DurationSec == 0 {
		duration = 60 * time.Second
	}
	if duration < time.Second || duration > n.Limits.MaxDuration {
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_duration", "探测时长超出节点允许的范围"}
	}
	size := req.PacketSize
	if size == 0 {
		size = 128
	}
	if size > n.Limits.MaxPacket {
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_size", "报文超过节点允许的大小"}
	}
	echo, err := tokenBytes(req.EchoToken)
	if err != nil {
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_token", "目标回显口令最长 32 字节"}
	}
	var payload, expect []byte
	if req.Profile == "custom-udp" {
		payload, err = decodeHex(req.PayloadHex)
		if err != nil || len(payload) == 0 || len(payload) > n.Limits.MaxPacket {
			return jobSpec{}, &apiError{http.StatusBadRequest, "bad_payload", "自定义载荷需要是不超过上限的十六进制"}
		}
		if req.ExpectHex != "" {
			expect, err = decodeHex(req.ExpectHex)
			if err != nil {
				return jobSpec{}, &apiError{http.StatusBadRequest, "bad_payload", "预期响应需要是十六进制"}
			}
		}
	}
	ip, err := targetOK(ctx, n.Resolver, req.Target, n.AllowPrivate, n.ExtraNets)
	if err != nil {
		var dnsErr *net.DNSError
		if errors.As(err, &dnsErr) {
			return jobSpec{}, &apiError{http.StatusBadRequest, "dns", "域名无法解析"}
		}
		if errors.Is(err, errForbiddenTarget) {
			return jobSpec{}, &apiError{http.StatusForbidden, "forbidden_target", "远程节点默认不探测本机、内网、链路本地或云元数据地址。管理员开放局域网后才能测这些地址"}
		}
		return jobSpec{}, &apiError{http.StatusBadRequest, "bad_target", "目标地址无效"}
	}
	return jobSpec{
		Host: req.Target, Port: req.Port, Profile: req.Profile, IP: ip,
		Interval: interval, Timeout: timeout, Duration: duration, PacketSize: size,
		Echo: echo, DNSName: req.DNSName, Payload: payload, Expect: expect,
	}, nil
}

func (n *Node) start(spec jobSpec) (*probeJob, error) {
	p, err := newProber(spec)
	if err != nil {
		return nil, err
	}
	id, err := newID()
	if err != nil {
		_ = p.Close()
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), spec.Duration)
	job := &probeJob{
		id:      id,
		expires: time.Now().Add(spec.Duration),
		cancel:  cancel,
		events:  make(chan sampleMsg, 64),
		attach:  make(chan struct{}),
		done:    make(chan struct{}),
	}
	n.mu.Lock()
	n.jobs[id] = job
	n.mu.Unlock()
	go n.run(ctx, job, spec, p)
	go n.attachDeadline(job)
	return job, nil
}

func (n *Node) attachDeadline(job *probeJob) {
	select {
	case <-job.attach:
	case <-job.done:
	case <-time.After(15 * time.Second):
		n.Stop(job.id)
	}
}

func (n *Node) run(ctx context.Context, job *probeJob, spec jobSpec, p prober) {
	defer func() {
		_ = p.Close()
		job.finish()
		n.mu.Lock()
		delete(n.jobs, job.id)
		n.mu.Unlock()
		<-n.sem
	}()
	book := &sampleBook{profile: spec.Profile}
	seq := 0
	emit := func(o Outcome) {
		book.add(o)
		seq++
		msg := sampleMsg{
			Seq: seq, Status: o.Status, Kind: o.Kind, Note: o.Note,
			Detail: o.Detail, Summary: book.summary(),
		}
		if o.HasRtt {
			ms := float64(o.Rtt) / float64(time.Millisecond)
			msg.RttMs = &ms
		}
		if book.jitter.has && o.Status == statusOK {
			v := book.jitter.value
			msg.JitterMs = &v
		}
		job.mu.Lock()
		job.last = msg
		job.mu.Unlock()
		select {
		case job.events <- msg:
		case <-ctx.Done():
		}
	}
	for {
		if err := n.pace.wait(ctx, spec.PacketSize); err != nil {
			return
		}
		started := time.Now()
		pctx, cancel := context.WithTimeout(ctx, spec.Timeout)
		out := p.Probe(pctx)
		cancel()
		if ctx.Err() != nil {
			return
		}
		emit(out)
		wait := spec.Interval - time.Since(started)
		if wait < 0 {
			wait = 0
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (n *Node) snapshot(w http.ResponseWriter, r *http.Request) {
	job := n.get(r.PathValue("id"))
	if job == nil {
		writeErr(w, http.StatusNotFound, "not_found", "任务不存在或已结束")
		return
	}
	job.mu.Lock()
	last := job.last
	job.mu.Unlock()
	if last.Seq == 0 && last.Status == "" {
		last = sampleMsg{Status: "pending", Summary: summaryMsg{Pending: 1}}
	}
	writeJSON(w, http.StatusOK, last)
}

func (n *Node) stream(w http.ResponseWriter, r *http.Request) {
	job := n.get(r.PathValue("id"))
	if job == nil {
		writeErr(w, http.StatusNotFound, "not_found", "任务不存在或已结束")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "error", "服务器不支持流式输出")
		return
	}
	job.attachOnce.Do(func() { close(job.attach) })
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	defer n.Stop(job.id)
	for {
		select {
		case <-r.Context().Done():
			return
		case msg, open := <-job.events:
			if !open {
				fmt.Fprintf(w, "event: end\ndata: {}\n\n")
				flusher.Flush()
				return
			}
			raw, _ := json.Marshal(msg)
			fmt.Fprintf(w, "event: sample\ndata: %s\n\n", raw)
			flusher.Flush()
		}
	}
}

func (n *Node) remove(w http.ResponseWriter, r *http.Request) {
	if !n.Stop(r.PathValue("id")) {
		writeErr(w, http.StatusNotFound, "not_found", "任务不存在或已结束")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (n *Node) get(id string) *probeJob {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.jobs[id]
}

func (n *Node) Stop(id string) bool {
	n.mu.Lock()
	job := n.jobs[id]
	n.mu.Unlock()
	if job == nil {
		return false
	}
	job.cancel()
	return true
}

func (n *Node) reap() {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for range t.C {
		now := time.Now()
		n.mu.Lock()
		var expired []string
		for id, job := range n.jobs {
			if now.After(job.expires) {
				expired = append(expired, id)
			}
		}
		n.mu.Unlock()
		for _, id := range expired {
			n.Stop(id)
		}
	}
}

func (n *Node) jobCount() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.jobs)
}

type probeJob struct {
	id         string
	expires    time.Time
	cancel     context.CancelFunc
	events     chan sampleMsg
	attach     chan struct{}
	attachOnce sync.Once
	mu         sync.Mutex
	last       sampleMsg
	once       sync.Once
	done       chan struct{}
}

func (j *probeJob) finish() {
	j.once.Do(func() {
		close(j.events)
		close(j.done)
	})
}

func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

func bearer(h string) string {
	const p = "Bearer "
	if len(h) < len(p) || !strings.EqualFold(h[:len(p)], p) {
		return ""
	}
	return strings.TrimSpace(h[len(p):])
}

func decodeHex(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, " ", "")
	if len(s)%2 == 1 {
		return nil, errors.New("odd hex")
	}
	return hex.DecodeString(s)
}

type apiError struct {
	status int
	code   string
	msg    string
}

func (e *apiError) Error() string { return e.msg }

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": code, "message": msg})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type paced struct {
	mu       sync.Mutex
	probes   int
	bytes    int
	window   time.Time
	maxProbe int
	maxBytes int
}

func newPaced(maxProbe, maxBytes int) *paced {
	return &paced{maxProbe: maxProbe, maxBytes: maxBytes, window: time.Now()}
}

func (p *paced) wait(ctx context.Context, packet int) error {
	if packet < 1 {
		packet = 1
	}
	for {
		p.mu.Lock()
		now := time.Now()
		if now.Sub(p.window) >= time.Second {
			p.window = now
			p.probes = 0
			p.bytes = 0
		}
		if p.probes < p.maxProbe && p.bytes+packet <= p.maxBytes {
			p.probes++
			p.bytes += packet
			p.mu.Unlock()
			return nil
		}
		wait := time.Second - now.Sub(p.window)
		p.mu.Unlock()
		if wait < 10*time.Millisecond {
			wait = 10 * time.Millisecond
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
