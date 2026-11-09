package main

import (
	"context"
	"flag"
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
	bind := flag.String("bind", envStr("NQ_BIND", "0.0.0.0"), "reflector bind address")
	tcpPort := flag.Int("tcp-port", envInt("NQ_TCP_PORT", 19090), "TCP echo port (0 disables)")
	udpPort := flag.Int("udp-port", envInt("NQ_UDP_PORT", 19091), "UDP echo port (0 disables)")
	tokenFlag := flag.String("token", envStr("NQ_TOKEN", ""), "optional echo token written into NQ frames, max 32 bytes; empty accepts any echo token")
	nodeToken := flag.String("node-token", envStr("NQ_NODE_TOKEN", ""), "optional control-plane token; empty makes the node public")
	mode := flag.String("mode", envStr("NQ_MODE", "reflector"), "reflector, node, or both")
	controlAddr := flag.String("control-addr", envStr("NQ_CONTROL_ADDR", "127.0.0.1:8443"), "node control listen address")
	allowPrivate := flag.Bool("allow-private", envBool("NQ_ALLOW_PRIVATE", false), "let the node probe loopback and private addresses (metadata stays blocked)")
	allowNets := flag.String("allow-nets", envStr("NQ_ALLOW_NETS", ""), "comma-separated extra CIDRs the node may probe")
	tlsCert := flag.String("tls-cert", envStr("NQ_TLS_CERT", ""), "TLS certificate for the control API")
	tlsKey := flag.String("tls-key", envStr("NQ_TLS_KEY", ""), "TLS private key for the control API")
	verbose := flag.Bool("v", false, "log each echoed packet")
	flag.Parse()

	switch *mode {
	case "reflector", "node", "both":
	default:
		log.Fatal("-mode must be reflector, node, or both")
	}
	if *tcpPort < 0 || *tcpPort > 65535 || *udpPort < 0 || *udpPort > 65535 {
		log.Fatal("ports must be between 0 and 65535")
	}
	if (*mode == "reflector" || *mode == "both") && *tcpPort == 0 && *udpPort == 0 {
		log.Fatal("reflector mode needs -tcp-port and/or -udp-port")
	}
	if (*tlsCert == "") != (*tlsKey == "") {
		log.Fatal("-tls-cert and -tls-key must be set together")
	}

	tok, err := tokenBytes(*tokenFlag)
	if err != nil {
		log.Fatal(err)
	}
	extra, err := parseNets(*allowNets)
	if err != nil {
		log.Fatal(err)
	}

	errCh := make(chan error, 4)
	var srv *Server
	if *mode == "reflector" || *mode == "both" {
		srv = &Server{Token: tok, Required: *tokenFlag != "", Verbose: *verbose}
		startReflector(srv, *bind, *tcpPort, *udpPort, errCh)
		if srv.Required {
			log.Printf("echo token check enabled")
		} else {
			log.Printf("echo token check disabled")
		}
	}

	var httpSrv *http.Server
	if *mode == "node" || *mode == "both" {
		node := newNode(*nodeToken, *allowPrivate, extra, defaultLimits())
		httpSrv = &http.Server{
			Addr:              *controlAddr,
			Handler:           node.Handler(),
			ReadHeaderTimeout: 5 * time.Second,
			IdleTimeout:       2 * time.Minute,
		}
		ln, err := net.Listen("tcp", *controlAddr)
		if err != nil {
			log.Fatalf("control listen %s: %v", *controlAddr, err)
		}
		go func() {
			var serveErr error
			if *tlsCert != "" {
				log.Printf("node control listening with TLS on %s", ln.Addr())
				serveErr = httpSrv.ServeTLS(ln, *tlsCert, *tlsKey)
			} else {
				log.Printf("node control listening on %s (no TLS; put an HTTPS reverse proxy in front if this is reachable from the internet)", ln.Addr())
				serveErr = httpSrv.Serve(ln)
			}
			if serveErr != nil && serveErr != http.ErrServerClosed {
				errCh <- serveErr
			}
		}()
		if node.Public() && !loopbackHost(*controlAddr) {
			log.Printf("WARNING: this node is PUBLIC. Anyone who can reach %s can start bounded probes. Set -node-token to require a control token. Caps stay on: jobs=%d duration=%s interval>=%s probes/s=%d bandwidth=%dB/s",
				*controlAddr, node.Limits.MaxJobs, node.Limits.MaxDuration, node.Limits.MinInterval, node.Limits.MaxProbePerSec, node.Limits.MaxBytesPerSec)
		} else if node.Public() {
			log.Printf("node is public and bound to loopback; no control token is required")
		} else {
			log.Printf("node is private; a control token is required and is not logged")
		}
		if *allowPrivate {
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

func envStr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}

func envBool(key string, fallback bool) bool {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}
