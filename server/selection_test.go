package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSelectionLedgerDoesNotCountFallback(t *testing.T) {
	ledger := &selectionLedger{candidates: 2}
	miss := Outcome{
		Status: statusTimeout,
		Kind:   kindProbe,
		Note:   "未收到回显",
		Detail: map[string]string{"address": "2001:db8::1", "family": "IPv6"},
	}
	commit, skipped := ledger.take(miss, false)
	if commit != nil || skipped != 0 {
		t.Fatalf("held failure was counted: %+v %d", commit, skipped)
	}
	ok := Outcome{
		Status: statusOK,
		Kind:   kindProbe,
		HasRtt: true,
		Rtt:    5 * time.Millisecond,
		Note:   "收到回显",
		Detail: map[string]string{"address": "203.0.113.5", "family": "IPv4"},
	}
	commit, skipped = ledger.take(ok, true)
	if skipped != 1 || len(commit) != 1 || commit[0].SelectionSkipped != 1 {
		t.Fatalf("success %+v skipped %d", commit, skipped)
	}
	if commit[0].Detail["fallback"] == "" || !containsAll(commit[0].Detail["fallback"], "2001:db8::1", "203.0.113.5", "没有计入") {
		t.Fatalf("fallback %q", commit[0].Detail["fallback"])
	}
	book := &sampleBook{profile: "nq-udp"}
	book.add(commit[0])
	summary := book.summary()
	if summary.Sent != 1 || summary.OK != 1 || summary.Timeout != 0 || summary.ProbeLossPct == nil || *summary.ProbeLossPct != 0 {
		t.Fatalf("summary %+v", summary)
	}
	if summary.SelectionSkipped != 1 || summary.MinRttMs == nil || *summary.MinRttMs != 5 || summary.P95RttMs == nil || *summary.P95RttMs != 5 {
		t.Fatalf("stats %+v", summary)
	}
}

func TestSelectionLedgerCommitsTotalFailure(t *testing.T) {
	ledger := &selectionLedger{candidates: 2}
	first := Outcome{Status: statusTimeout, Kind: kindProbe, Detail: map[string]string{"address": "2001:db8::1", "family": "IPv6"}}
	second := Outcome{Status: statusTimeout, Kind: kindProbe, Detail: map[string]string{"address": "203.0.113.5", "family": "IPv4"}}
	if commit, _ := ledger.take(first, false); commit != nil {
		t.Fatal("first failure committed early")
	}
	commit, _ := ledger.take(second, false)
	if len(commit) != 2 {
		t.Fatalf("commit %+v", commit)
	}
	book := &sampleBook{profile: "nq-udp"}
	for _, outcome := range commit {
		book.add(outcome)
	}
	summary := book.summary()
	if summary.OK != 0 || summary.Sent != 2 || summary.ProbeLossPct == nil || *summary.ProbeLossPct != 100 {
		t.Fatalf("summary %+v", summary)
	}
}

func TestMeasuredTimeoutStillCounts(t *testing.T) {
	ledger := &selectionLedger{candidates: 2}
	ok := Outcome{Status: statusOK, Kind: kindProbe, HasRtt: true, Rtt: 4 * time.Millisecond}
	if commit, _ := ledger.take(ok, true); len(commit) != 1 {
		t.Fatal(commit)
	}
	miss := Outcome{Status: statusTimeout, Kind: kindProbe}
	commit, _ := ledger.take(miss, false)
	if len(commit) != 1 || commit[0].Status != statusTimeout {
		t.Fatalf("post-selection miss hidden: %+v", commit)
	}
	book := &sampleBook{profile: "nq-udp"}
	book.add(ok)
	book.add(commit[0])
	summary := book.summary()
	if summary.ProbeLossPct == nil || *summary.ProbeLossPct != 50 || summary.Sent != 2 {
		t.Fatalf("summary %+v", summary)
	}
}

func TestLatencyRanks(t *testing.T) {
	if nearestRank95(1) != 1 || nearestRank95(2) != 2 || nearestRank95(4) != 4 || nearestRank95(5) != 5 || nearestRank95(20) != 19 {
		t.Fatalf("ranks %d %d %d %d %d", nearestRank95(1), nearestRank95(2), nearestRank95(4), nearestRank95(5), nearestRank95(20))
	}
	min, mean, median, p95, max, ok := latencyOf([]float64{1, 2, 3, 4})
	if !ok || min != 1 || mean != 2.5 || median != 2.5 || p95 != 4 || max != 4 {
		t.Fatalf("four %v %v %v %v %v", min, mean, median, p95, max)
	}
	_, _, median, p95, _, ok = latencyOf([]float64{1, 2, 3, 4, 10})
	if !ok || median != 3 || p95 != 10 {
		t.Fatalf("five median %v p95 %v", median, p95)
	}
	_, _, _, _, _, ok = latencyOf(nil)
	if ok {
		t.Fatal("empty latency")
	}
	book := &sampleBook{profile: "nq-udp"}
	book.add(Outcome{Status: statusOK, Kind: kindProbe, HasRtt: true, Rtt: time.Millisecond})
	book.add(Outcome{Status: statusOK, Kind: kindProbe, HasRtt: true, Rtt: 4 * time.Millisecond})
	summary := book.summary()
	if summary.MinRttMs == nil || *summary.MinRttMs != 1 || summary.MaxRttMs == nil || *summary.MaxRttMs != 4 || summary.MedianRttMs == nil || *summary.MedianRttMs != 2.5 {
		t.Fatalf("aliased latency %+v", summary)
	}
}

func TestDialFirstSkipsFailedCandidate(t *testing.T) {
	good, bad := net.Pipe()
	defer good.Close()
	defer bad.Close()
	v6 := net.ParseIP("2001:db8::1")
	v4 := net.ParseIP("203.0.113.5")
	calls := 0
	conn, used, skipped, err := dialFirst(context.Background(), []net.IP{v6, v4}, time.Second, func(ctx context.Context, ip net.IP) (net.Conn, error) {
		calls++
		if ip.Equal(v6) {
			return nil, errors.New("network unreachable")
		}
		return good, nil
	})
	if err != nil || !used.Equal(v4) || len(skipped) != 1 || calls != 2 {
		t.Fatalf("used %v skipped %v err %v calls %d", used, skipped, err, calls)
	}
	_ = conn.Close()

	_, _, skipped, err = dialFirst(context.Background(), []net.IP{v6, v4}, time.Second, func(context.Context, net.IP) (net.Conn, error) {
		return nil, context.DeadlineExceeded
	})
	if err == nil || len(skipped) != 2 {
		t.Fatalf("all-fail err %v skipped %v", err, skipped)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, _, err = dialFirst(ctx, []net.IP{v6, v4}, time.Second, func(context.Context, net.IP) (net.Conn, error) {
		t.Fatal("dialled after cancel")
		return nil, nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel err %v", err)
	}
}

func TestResolveTargetsKeepsOrder(t *testing.T) {
	resolver := stubResolver{[]net.IP{net.ParseIP("2001:db8::1"), net.ParseIP("203.0.113.5")}}
	ips, err := resolveTargets(context.Background(), resolver, "example.com", false, nil)
	if err != nil || len(ips) != 2 || ips[0].String() != "2001:db8::1" || ips[1].String() != "203.0.113.5" {
		t.Fatalf("ips %v err %v", ips, err)
	}
	first, err := targetOK(context.Background(), resolver, "example.com", false, nil)
	if err != nil || first.String() != "2001:db8::1" {
		t.Fatalf("first %v err %v", first, err)
	}
}

func TestStopDoesNotRecordInFlight(t *testing.T) {
	blackhole, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer blackhole.Close()
	node := newNode("", true, nil, testLimits())
	srv := httptest.NewServer(node.Handler())
	defer srv.Close()
	id := createJob(t, srv.URL, "", map[string]any{
		"target": "127.0.0.1", "port": blackhole.LocalAddr().(*net.UDPAddr).Port,
		"profile": "nq-udp", "intervalMs": 200, "timeoutMs": 4000, "durationSec": 5, "packetSize": 80,
	})
	time.Sleep(50 * time.Millisecond)
	req, err := http.NewRequest(http.MethodDelete, srv.URL+"/v1/jobs/"+id, nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	time.Sleep(100 * time.Millisecond)
	snapReq, err := http.NewRequest(http.MethodGet, srv.URL+"/v1/jobs/"+id, nil)
	if err != nil {
		t.Fatal(err)
	}
	snapRes, err := http.DefaultClient.Do(snapReq)
	if err != nil {
		t.Fatal(err)
	}
	defer snapRes.Body.Close()
	if snapRes.StatusCode == http.StatusNotFound {
		return
	}
	body, _ := io.ReadAll(snapRes.Body)
	var msg sampleMsg
	if err := json.Unmarshal(body, &msg); err != nil {
		t.Fatal(err)
	}
	if msg.Summary.Sent > 0 || msg.Status == statusTimeout || msg.Status == statusUnknown {
		t.Fatalf("cancelled probe counted %s", body)
	}
}

func TestNodeUDPFallbackIsNotLoss(t *testing.T) {
	drop, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.2")})
	if err != nil {
		t.Skipf("127.0.0.2 unavailable: %v", err)
	}
	defer drop.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			if _, _, err := drop.ReadFromUDP(buf); err != nil {
				return
			}
		}
	}()
	port := drop.LocalAddr().(*net.UDPAddr).Port
	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	if err != nil {
		t.Skipf("paired echo: %v", err)
	}
	defer echo.Close()
	reflector := &Server{}
	go reflector.ServeUDP(echo)
	defer reflector.Close()

	node := newNode("", true, nil, testLimits())
	node.Resolver = stubResolver{[]net.IP{net.ParseIP("127.0.0.2"), net.ParseIP("127.0.0.1")}}
	srv := httptest.NewServer(node.Handler())
	defer srv.Close()
	id := createJob(t, srv.URL, "", map[string]any{
		"target": "example.test", "port": port, "profile": "nq-udp",
		"intervalMs": 200, "timeoutMs": 300, "durationSec": 5, "packetSize": 80,
	})
	sample := readOneSample(t, srv.URL, "", id)
	if sample.Status != statusOK || sample.Detail["address"] != "127.0.0.1" || sample.Detail["family"] != "IPv4" {
		t.Fatalf("sample %+v", sample)
	}
	if sample.Summary.Sent != 1 || sample.Summary.Timeout != 0 || sample.Summary.ProbeLossPct == nil || *sample.Summary.ProbeLossPct != 0 || sample.Summary.SelectionSkipped != 1 {
		t.Fatalf("loss polluted %+v", sample.Summary)
	}
	if !strings.Contains(sample.Detail["fallback"], "127.0.0.2") || !strings.Contains(sample.Detail["fallback"], "没有计入") {
		t.Fatalf("fallback %q", sample.Detail["fallback"])
	}
}

func containsAll(text string, parts ...string) bool {
	for _, part := range parts {
		if !strings.Contains(text, part) {
			return false
		}
	}
	return true
}
