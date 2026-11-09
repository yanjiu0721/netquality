package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

var errForbiddenTarget = errors.New("forbidden target")

// metadataNames are never probed, even when the operator allows LAN targets.
var metadataNames = map[string]struct{}{
	"localhost":                {},
	"metadata":                 {},
	"metadata.google.internal": {},
	"metadata.google.com":      {},
}

var metadataIP = net.ParseIP("169.254.169.254")

// targetOK decides whether a remote node may dial this address.
// Loopback, private, link-local and cloud metadata are rejected unless
// allowPrivate is set. Metadata addresses stay blocked either way.
// Every resolved address is checked so a later DNS answer cannot rebind
// the dial onto a forbidden IP; the caller dials only the returned IP.
func targetOK(ctx context.Context, resolver resolver, host string, allowPrivate bool, extra []*net.IPNet) (net.IP, error) {
	host = strings.TrimSpace(host)
	host = strings.Trim(host, "[]")
	if host == "" {
		return nil, errors.New("empty host")
	}
	if _, banned := metadataNames[strings.ToLower(host)]; banned {
		return nil, fmt.Errorf("%w: metadata or localhost name", errForbiddenTarget)
	}
	if ip := net.ParseIP(host); ip != nil {
		if !ipAllowed(ip, allowPrivate, extra) {
			return nil, fmt.Errorf("%w: %s", errForbiddenTarget, ip.String())
		}
		return ip, nil
	}
	if resolver == nil {
		resolver = net.DefaultResolver
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	addrs, err := resolver.LookupIPAddr(lookupCtx, host)
	if err != nil {
		return nil, err
	}
	if len(addrs) == 0 {
		return nil, &net.DNSError{Err: "no addresses", Name: host, IsNotFound: true}
	}
	var allowed []net.IP
	for _, addr := range addrs {
		if ipAllowed(addr.IP, allowPrivate, extra) {
			allowed = append(allowed, addr.IP)
		}
	}
	if len(allowed) == 0 {
		return nil, fmt.Errorf("%w: %s resolved only to blocked addresses", errForbiddenTarget, host)
	}
	if len(allowed) != len(addrs) {
		return nil, fmt.Errorf("%w: %s resolved to a mix of public and blocked addresses", errForbiddenTarget, host)
	}
	return allowed[0], nil
}

func ipAllowed(ip net.IP, allowPrivate bool, extra []*net.IPNet) bool {
	if ip == nil {
		return false
	}
	if ip.Equal(metadataIP) || ip.Equal(net.ParseIP("fd00:ec2::254")) {
		return false
	}
	for _, n := range extra {
		if n.Contains(ip) {
			return true
		}
	}
	if ip.IsMulticast() || ip.IsUnspecified() || ip.IsLinkLocalMulticast() {
		return false
	}
	if allowPrivate {
		return true
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return false
	}
	return true
}

type resolver interface {
	LookupIPAddr(context.Context, string) ([]net.IPAddr, error)
}
