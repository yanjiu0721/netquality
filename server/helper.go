// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"time"
)

// runHelper speaks one JSON request per line and writes one JSON outcome.
// The Flutter client uses this for local HTTP probes so it runs the same
// engine as a remote node. Logs stay off stdout.
func runHelper(r io.Reader, w io.Writer) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	enc := json.NewEncoder(w)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var req helperRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			_ = enc.Encode(outcomeWire(httpFail(statusError, "请求无法解析")))
			continue
		}
		if req.Profile != "" && req.Profile != "http" {
			_ = enc.Encode(outcomeWire(httpFail(statusError, "本机引擎目前只负责 HTTP 探测")))
			continue
		}
		out := probeHTTP(context.Background(), req.ctxInput())
		_ = enc.Encode(outcomeWire(out))
	}
	return sc.Err()
}

type helperRequest struct {
	Profile     string          `json:"profile"`
	Target      string          `json:"target"`
	Port        int             `json:"port"`
	TimeoutMs   int             `json:"timeoutMs"`
	AllowIPv4   *bool           `json:"allowIPv4"`
	AllowIPv6   *bool           `json:"allowIPv6"`
	HTTP        *httpOptionsReq `json:"http"`
	Insecure    bool            `json:"insecure"`
}

type httpOptionsReq struct {
	Version      string `json:"version"`
	Resolve      string `json:"resolve"`
	Method       string `json:"method"`
	Body         string `json:"body"`
	Referer      string `json:"referer"`
	UserAgent    string `json:"userAgent"`
	Cookies      string `json:"cookies"`
	MaxRedirects *int   `json:"maxRedirects"`
}

func (h helperRequest) ctxInput() HTTPInput {
	in := HTTPInput{
		Target:       h.Target,
		Port:         h.Port,
		Timeout:      0,
		Allow4:       flagOrDefault(h.AllowIPv4, true),
		Allow6:       flagOrDefault(h.AllowIPv6, true),
		CheckSafety:  false,
		AllowPrivate: true,
		Insecure:     h.Insecure,
	}
	if h.TimeoutMs > 0 {
		in.Timeout = time.Duration(h.TimeoutMs) * time.Millisecond
	}
	applyHTTPOptions(&in, h.HTTP)
	return in
}

func applyHTTPOptions(in *HTTPInput, opt *httpOptionsReq) {
	if opt == nil {
		return
	}
	in.Version = opt.Version
	in.Resolve = opt.Resolve
	in.Method = opt.Method
	in.Body = opt.Body
	in.Referer = opt.Referer
	in.UserAgent = opt.UserAgent
	in.Cookies = opt.Cookies
	if opt.MaxRedirects != nil {
		in.MaxRedirects = *opt.MaxRedirects
		in.MaxSet = true
	}
}

type wireOutcome struct {
	Status string            `json:"status"`
	Kind   string            `json:"kind"`
	RttMs  *float64          `json:"rttMs,omitempty"`
	Note   string            `json:"note,omitempty"`
	Detail map[string]string `json:"detail,omitempty"`
}

func outcomeWire(o Outcome) wireOutcome {
	w := wireOutcome{Status: o.Status, Kind: o.Kind, Note: o.Note, Detail: o.Detail}
	if o.HasRtt {
		ms := float64(o.Rtt) / float64(1e6)
		w.RttMs = &ms
	}
	return w
}
