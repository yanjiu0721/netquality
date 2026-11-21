// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"errors"
	"net"
	"strings"
)

// familyError is a user-facing refusal to use an address family.
type familyError struct{ msg string }

func (e *familyError) Error() string { return e.msg }

func familyMessage(msg string) error { return &familyError{msg: msg} }

// filterFamily keeps only the address families the user turned on.
// A literal address of a disabled family is refused. When every resolved
// address is in a disabled family, the probe does not start.
func filterFamily(host string, ips []net.IP, allow4, allow6 bool) ([]net.IP, error) {
	if !allow4 && !allow6 {
		return nil, familyMessage("IPv4 和 IPv6 都已关闭，无法开始探测")
	}
	literal := net.ParseIP(strings.Trim(strings.TrimSpace(host), "[]"))
	if literal != nil {
		if literal.To4() != nil && !allow4 {
			return nil, familyMessage("目标是 IPv4 地址，但 IPv4 已关闭")
		}
		if literal.To4() == nil && !allow6 {
			return nil, familyMessage("目标是 IPv6 地址，但 IPv6 已关闭")
		}
	}
	out := make([]net.IP, 0, len(ips))
	for _, ip := range ips {
		if ip == nil {
			continue
		}
		if ip.To4() != nil {
			if allow4 {
				out = append(out, ip)
			}
			continue
		}
		if allow6 {
			out = append(out, ip)
		}
	}
	if len(out) == 0 {
		return nil, familyMessage("解析到的地址都不在已打开的地址族里")
	}
	return out, nil
}

func flagOrDefault(v *bool, fallback bool) bool {
	if v == nil {
		return fallback
	}
	return *v
}

// preferIP rotates ips so preferred is first when it is one of them.
func preferIP(ips []net.IP, preferred net.IP) []net.IP {
	if preferred == nil || len(ips) == 0 {
		return ips
	}
	for i, ip := range ips {
		if ip.Equal(preferred) {
			if i == 0 {
				return ips
			}
			out := make([]net.IP, 0, len(ips))
			out = append(out, ips[i:]...)
			out = append(out, ips[:i]...)
			return out
		}
	}
	return ips
}

func asFamily(err error) (*familyError, bool) {
	var fe *familyError
	if errors.As(err, &fe) {
		return fe, true
	}
	return nil, false
}
