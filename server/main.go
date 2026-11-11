// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	cfg, err := loadConfig(os.Args[1:], os.Environ())
	if err != nil {
		if errors.Is(err, errHelp) {
			os.Exit(0)
		}
		log.Fatal(err)
	}
	log.Printf("%s", cfg.Summary())

	tok, err := tokenBytes(cfg.Token)
	if err != nil {
		log.Fatal(err)
	}
	extra, err := parseNets(cfg.AllowNets)
	if err != nil {
		log.Fatal(err)
	}

	errCh := make(chan error, 4)
	var srv *Server
	if cfg.Mode == "reflector" || cfg.Mode == "both" {
		srv = &Server{Token: tok, Required: cfg.Token != "", Verbose: cfg.Verbose}
		startReflector(srv, cfg.Bind, cfg.TCPPort, cfg.UDPPort, errCh)
		if srv.Required {
			log.Printf("echo token check enabled")
		} else {
			log.Printf("echo token check disabled")
		}
	}

	var httpSrv *http.Server
	if cfg.Mode == "node" || cfg.Mode == "both" {
		node := newNode(cfg.NodeToken, cfg.AllowPrivate, extra, defaultLimits())
		httpSrv = &http.Server{
			Addr:              cfg.ControlAddr,
			Handler:           node.Handler(),
			ReadHeaderTimeout: 5 * time.Second,
			IdleTimeout:       2 * time.Minute,
		}
		ln, err := net.Listen("tcp", cfg.ControlAddr)
		if err != nil {
			log.Fatalf("control listen %s: %v", cfg.ControlAddr, err)
		}
		go func() {
			var serveErr error
			if cfg.TLSCert != "" {
				log.Printf("node control listening with TLS on %s", ln.Addr())
				serveErr = httpSrv.ServeTLS(ln, cfg.TLSCert, cfg.TLSKey)
			} else {
				log.Printf("node control listening on %s (no TLS; put an HTTPS reverse proxy in front if this is reachable from the internet)", ln.Addr())
				serveErr = httpSrv.Serve(ln)
			}
			if serveErr != nil && serveErr != http.ErrServerClosed {
				errCh <- serveErr
			}
		}()
		if node.Public() && !loopbackHost(cfg.ControlAddr) {
			log.Printf("WARNING: this node is PUBLIC. Anyone who can reach %s can start bounded probes. Set NQ_NODE_TOKEN or -node-token to require a control token. Caps stay on: jobs=%d duration=%s interval>=%s probes/s=%d bandwidth=%dB/s",
				cfg.ControlAddr, node.Limits.MaxJobs, node.Limits.MaxDuration, node.Limits.MinInterval, node.Limits.MaxProbePerSec, node.Limits.MaxBytesPerSec)
		} else if node.Public() {
			log.Printf("node is public and bound to loopback; no control token is required")
		} else {
			log.Printf("node is private; a control token is required and is not logged")
		}
		if cfg.AllowPrivate {
			log.Printf("private and loopback targets are allowed; metadata addresses stay blocked")
		}
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sig:
			log.Printf("shutting down")
			if srv != nil {
				srv.Close()
			}
			if httpSrv != nil {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				_ = httpSrv.Shutdown(ctx)
				cancel()
			}
			return
		case err := <-errCh:
			log.Printf("listener stopped: %v", err)
			if srv != nil {
				srv.Close()
			}
			if httpSrv != nil {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				_ = httpSrv.Shutdown(ctx)
				cancel()
			}
			os.Exit(1)
		case <-ticker.C:
			if srv != nil {
				req, rep, rej := srv.Stats()
				log.Printf("stats requests=%d replies=%d rejected=%d", req, rep, rej)
			}
		}
	}
}

func startReflector(srv *Server, bind string, tcpPort, udpPort int, errCh chan error) {
	if tcpPort > 0 {
		addr := net.JoinHostPort(bind, strconv.Itoa(tcpPort))
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			log.Fatalf("tcp listen %s: %v", addr, err)
		}
		log.Printf("TCP reflector listening on %s", ln.Addr())
		go func() {
			srv.ServeTCP(ln)
			errCh <- fmt.Errorf("tcp listener closed")
		}()
	}
	if udpPort > 0 {
		addr := net.JoinHostPort(bind, strconv.Itoa(udpPort))
		udpAddr, err := net.ResolveUDPAddr("udp", addr)
		if err != nil {
			log.Fatalf("udp resolve %s: %v", addr, err)
		}
		conn, err := net.ListenUDP("udp", udpAddr)
		if err != nil {
			log.Fatalf("udp listen %s: %v", addr, err)
		}
		log.Printf("UDP reflector listening on %s", conn.LocalAddr())
		go func() {
			srv.ServeUDP(conn)
			errCh <- fmt.Errorf("udp listener closed")
		}()
	}
}

func parseNets(s string) ([]*net.IPNet, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	var out []*net.IPNet
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if !strings.Contains(part, "/") {
			ip := net.ParseIP(part)
			if ip == nil {
				return nil, fmt.Errorf("bad allow entry %q", part)
			}
			bits := 32
			if ip.To4() == nil {
				bits = 128
			}
			part = ip.String() + "/" + strconv.Itoa(bits)
		}
		_, n, err := net.ParseCIDR(part)
		if err != nil {
			return nil, fmt.Errorf("bad allow entry %q: %w", part, err)
		}
		out = append(out, n)
	}
	return out, nil
}

func loopbackHost(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	host = strings.Trim(host, "[]")
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
