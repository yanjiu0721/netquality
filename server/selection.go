// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"
)

const appVersion = "1.1.4"

// dialState is shared by the job runner and the prober. Both hold a copy of
// jobSpec, so the mutable address choice has to live behind a pointer.
type dialState struct {
	picker   *endpointPicker
	used     net.IP
	fallback string
	skipped  int
}

type endpointPicker struct {
	ips    []net.IP
	index  int
	misses int
	locked bool
	sticky int
}

func newEndpointPicker(ips []net.IP) *endpointPicker {
	return &endpointPicker{ips: append([]net.IP(nil), ips...), sticky: 3}
}

func (p *endpointPicker) current() net.IP {
	if p == nil || len(p.ips) == 0 {
		return nil
	}
	return p.ips[p.index]
}

func (p *endpointPicker) lock(ip net.IP) {
	for i, cand := range p.ips {
		if cand.Equal(ip) {
			p.index = i
			p.locked = true
			p.misses = 0
			return
		}
	}
}

// record matches the client EndpointPicker: one miss rotates until some
// address has answered; after that, sticky misses are required.
func (p *endpointPicker) record(responded bool) bool {
	if responded {
		p.locked = true
		p.misses = 0
		return false
	}
	p.misses++
	limit := 1
	if p.locked {
		limit = p.sticky
	}
	if len(p.ips) < 2 || p.misses < limit {
		return false
	}
	p.misses = 0
	p.locked = false
	p.index = (p.index + 1) % len(p.ips)
	return true
}

func (s jobSpec) candidates() []net.IP {
	if s.state != nil && s.state.picker != nil && len(s.state.picker.ips) > 0 {
		return s.state.picker.ips
	}
	if s.IP != nil {
		return []net.IP{s.IP}
	}
	return nil
}

func (s jobSpec) dialIP() net.IP {
	if s.state != nil && s.state.picker != nil {
		if ip := s.state.picker.current(); ip != nil {
			return ip
		}
	}
	if s.IP != nil {
		return s.IP
	}
	return nil
}

func familyOf(ip net.IP) string {
	if ip == nil {
		return ""
	}
	if ip.To4() != nil {
		return "IPv4"
	}
	return "IPv6"
}

func copyDetail(in map[string]string) map[string]string {
	out := make(map[string]string, len(in)+2)
	for k, v := range in {
		out[k] = v
	}
	return out
}

func stampIP(o Outcome, ip net.IP) Outcome {
	if ip == nil {
		return o
	}
	o.Detail = copyDetail(o.Detail)
	o.Detail["address"] = ip.String()
	o.Detail["family"] = familyOf(ip)
	return o
}

// decorate attaches the address actually dialed. Candidate-connect failures
// that were skipped in favor of a working address are copied onto this one
// outcome and then cleared, so they are not repeated on later probes.
func (s jobSpec) decorate(o Outcome) Outcome {
	if s.state == nil {
		if s.IP != nil {
			return stampIP(o, s.IP)
		}
		return o
	}
	if s.state.used != nil {
		o = stampIP(o, s.state.used)
	}
	if s.state.fallback != "" {
		o.Detail = copyDetail(o.Detail)
		o.Detail["fallback"] = s.state.fallback
		s.state.fallback = ""
	}
	if s.state.skipped > 0 {
		o.SelectionSkipped += s.state.skipped
		s.state.skipped = 0
	}
	return o
}

func selectionResponded(status string) bool {
	switch status {
	case statusOK, statusProtocol, statusRefused:
		return true
	default:
		return false
	}
}

func datagramProfile(profile string) bool {
	switch profile {
	case "nq-udp", "udp-generic", "custom-udp", "dns", "minecraft-bedrock":
		return true
	default:
		return false
	}
}

type selectionLedger struct {
	candidates int
	measuring  bool
	held       []Outcome
}

func (l *selectionLedger) take(o Outcome, responded bool) (commit []Outcome, skipped int) {
	if l.candidates <= 1 {
		if responded {
			l.measuring = true
		}
		return []Outcome{o}, 0
	}
	if l.measuring {
		return []Outcome{o}, 0
	}
	if responded {
		skipped = len(l.held)
		if skipped > 0 {
			o.Detail = copyDetail(o.Detail)
			o.Detail["fallback"] = fallbackFromHeld(l.held, o)
			o.SelectionSkipped += skipped
		}
		l.held = nil
		l.measuring = true
		return []Outcome{o}, skipped
	}
	l.held = append(l.held, o)
	if len(l.held) >= l.candidates {
		commit = append([]Outcome(nil), l.held...)
		l.held = nil
		return commit, 0
	}
	return nil, 0
}

func fallbackFromHeld(held []Outcome, success Outcome) string {
	parts := make([]string, 0, len(held))
	for _, o := range held {
		addr := ""
		fam := ""
		if o.Detail != nil {
			addr = o.Detail["address"]
			fam = o.Detail["family"]
		}
		where := "未知地址"
		if addr != "" {
			where = addr
			if fam != "" {
				where = addr + "（" + fam + "）"
			}
		}
		why := o.Note
		if why == "" {
			why = "没有成功"
		}
		parts = append(parts, where+"："+why)
	}
	used := ""
	usedFam := ""
	if success.Detail != nil {
		used = success.Detail["address"]
		usedFam = success.Detail["family"]
	}
	usedText := "另一个地址"
	if used != "" {
		usedText = used
		if usedFam != "" {
			usedText = used + "（" + usedFam + "）"
		}
	}
	return "候选未成功：" + strings.Join(parts, "；") + "。已改用 " + usedText + "。这些失败没有计入正式丢包或失败率。"
}

type dialFunc func(context.Context, net.IP) (net.Conn, error)

// dialFirst tries each address with its own timeout. A failure is described
// and not returned as a separate measured attempt. If a later address
// connects, the skipped notes are returned for the diagnostic. If every
// address fails, err is the last error. A cancelled parent context does not
// become a measured timeout.
func dialFirst(ctx context.Context, ips []net.IP, timeout time.Duration, dial dialFunc) (net.Conn, net.IP, []string, error) {
	if len(ips) == 0 {
		return nil, nil, nil, errors.New("no address")
	}
	if timeout <= 0 {
		timeout = 1500 * time.Millisecond
	}
	var skipped []string
	var last error
	for _, ip := range ips {
		if err := ctx.Err(); err != nil {
			return nil, nil, skipped, err
		}
		dialCtx, cancel := context.WithTimeout(ctx, timeout)
		conn, err := dial(dialCtx, ip)
		cancel()
		if err == nil {
			return conn, ip, skipped, nil
		}
		if errors.Is(err, context.Canceled) && ctx.Err() != nil {
			return nil, nil, skipped, ctx.Err()
		}
		skipped = append(skipped, fmt.Sprintf("%s %s %s", familyOf(ip), ip.String(), classifyDial(err).Note))
		last = err
	}
	if last == nil {
		last = errors.New("连接失败")
	}
	return nil, nil, skipped, last
}

func dialSpecTCP(ctx context.Context, spec *jobSpec) (net.Conn, error) {
	ips := spec.candidates()
	start := 0
	if spec.state != nil && spec.state.picker != nil {
		start = spec.state.picker.index
	}
	rotated := make([]net.IP, 0, len(ips))
	for n := 0; n < len(ips); n++ {
		rotated = append(rotated, ips[(start+n)%len(ips)])
	}
	conn, ip, skipped, err := dialFirst(ctx, rotated, spec.Timeout, func(ctx context.Context, ip net.IP) (net.Conn, error) {
		return dialTCP(ctx, ip, spec.Port)
	})
	if spec.state != nil {
		spec.state.used = nil
		spec.state.fallback = ""
		spec.state.skipped = 0
	}
	if err != nil {
		if spec.state != nil && len(skipped) > 0 && !errors.Is(err, context.Canceled) {
			spec.state.fallback = "已尝试 " + strings.Join(skipped, "；") + "。没有地址连通，这次记为失败。"
		}
		return nil, err
	}
	if spec.state != nil {
		if spec.state.picker != nil {
			spec.state.picker.lock(ip)
		}
		spec.state.used = append(net.IP(nil), ip...)
		if len(skipped) > 0 {
			spec.state.skipped = len(skipped)
			spec.state.fallback = "候选未连通：" + strings.Join(skipped, "；") + "。已改用 " + ip.String() + "（" + familyOf(ip) + "）。这些失败没有计入正式丢包或失败率。"
		}
	}
	return conn, nil
}

func ensureUDP(conn *net.UDPConn, spec jobSpec) (*net.UDPConn, error) {
	want := spec.dialIP()
	if want == nil {
		return nil, errors.New("no address")
	}
	if conn != nil {
		if ra, ok := conn.RemoteAddr().(*net.UDPAddr); ok && ra.IP.Equal(want) {
			return conn, nil
		}
		_ = conn.Close()
	}
	return dialUDP(want, spec.Port)
}

// nearestRank95 is ceil(0.95*n) in integer arithmetic.
func nearestRank95(n int) int {
	if n <= 1 {
		return 1
	}
	rank := (95*n + 99) / 100
	if rank < 1 {
		return 1
	}
	if rank > n {
		return n
	}
	return rank
}

func latencyOf(samples []float64) (min, mean, median, p95, max float64, ok bool) {
	if len(samples) == 0 {
		return 0, 0, 0, 0, 0, false
	}
	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	var sum float64
	for _, v := range sorted {
		sum += v
	}
	n := len(sorted)
	if n%2 == 1 {
		median = sorted[n/2]
	} else {
		median = (sorted[n/2-1] + sorted[n/2]) / 2
	}
	rank := nearestRank95(n)
	return sorted[0], sum / float64(n), median, sorted[rank-1], sorted[n-1], true
}
