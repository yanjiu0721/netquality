package main

import "time"

const (
	statusOK       = "ok"
	statusTimeout  = "timeout"
	statusUnknown  = "unknown"
	statusRefused  = "refused"
	statusDNS      = "dns"
	statusProtocol = "protocol"
	statusError    = "error"

	kindConnect = "connect"
	kindProbe   = "probe"
	kindQuery   = "query"
)

// Outcome is one finished attempt. Pending attempts are never turned into
// a sample, so a chart cannot show a fake 100% before the probe completes.
type Outcome struct {
	Status    string
	Kind      string
	Rtt       time.Duration
	HasRtt    bool
	Note      string
	Detail    map[string]string
	Reconnect bool
}

type jitter struct {
	has   bool
	last  float64
	value float64
}

func (j *jitter) push(rttMs float64) float64 {
	if j.has {
		d := rttMs - j.last
		if d < 0 {
			d = -d
		}
		j.value += (d - j.value) / 16
	}
	j.last = rttMs
	j.has = true
	return j.value
}

// sampleBook folds finished outcomes. Rates use only completed attempts.
// "unknown" (no protocol reply) is not counted as proven packet loss.
type sampleBook struct {
	profile string

	sent        int
	completed   int
	ok          int
	timeout     int
	unknown     int
	refused     int
	dns         int
	protocol    int
	other       int
	reconnect   int
	consecutive int

	lastRttMs *float64
	jitter    jitter
	lastNote  string
	detail    map[string]string
}

func (b *sampleBook) add(o Outcome) {
	b.sent++
	b.completed++
	if o.Reconnect {
		b.reconnect++
	}
	if o.Note != "" {
		b.lastNote = o.Note
	}
	if len(o.Detail) > 0 {
		if b.detail == nil {
			b.detail = map[string]string{}
		}
		for k, v := range o.Detail {
			b.detail[k] = v
		}
	}
	switch o.Status {
	case statusOK:
		b.ok++
		b.consecutive = 0
		if o.HasRtt {
			ms := float64(o.Rtt) / float64(time.Millisecond)
			b.lastRttMs = &ms
			b.jitter.push(ms)
		}
	case statusTimeout:
		// Only a written NQ probe that never returned is probe-response loss.
		// A TCP connect timeout is a failed attempt, not a lost echo.
		if o.Kind == kindProbe {
			b.timeout++
		} else {
			b.other++
		}
		b.consecutive++
	case statusUnknown:
		b.unknown++
	case statusRefused:
		b.refused++
		b.consecutive++
	case statusDNS:
		b.dns++
		b.consecutive++
	case statusProtocol:
		b.protocol++
		b.consecutive++
	default:
		b.other++
		b.consecutive++
	}
}

func (b *sampleBook) summary() summaryMsg {
	s := summaryMsg{
		Sent:                b.sent,
		Pending:             0,
		Completed:           b.completed,
		OK:                  b.ok,
		Timeout:             b.timeout,
		Unknown:             b.unknown,
		Refused:             b.refused,
		DNS:                 b.dns,
		Protocol:            b.protocol,
		Other:               b.other,
		Reconnects:          b.reconnect,
		ConsecutiveFailures: b.consecutive,
		LastNote:            b.lastNote,
		Detail:              b.detail,
	}
	if b.lastRttMs != nil {
		v := *b.lastRttMs
		s.RttMs = &v
	}
	if b.jitter.has {
		v := b.jitter.value
		s.JitterMs = &v
	}
	if b.completed == 0 {
		return s
	}
	switch b.profile {
	case "nq-tcp", "nq-udp":
		// Echo was requested and did not come back. This is probe-response
		// loss, not a NIC packet-loss counter. TCP timeouts still land here
		// only after a frame was written; connect failures use other statuses.
		if b.timeout+b.ok > 0 {
			v := float64(b.timeout) * 100 / float64(b.timeout+b.ok)
			s.ProbeLossPct = &v
		}
	case "tcp-connect", "minecraft-java":
		denom := b.ok + b.timeout + b.refused + b.dns + b.protocol + b.other
		if denom > 0 {
			v := float64(denom-b.ok) * 100 / float64(denom)
			s.FailurePct = &v
		}
	default:
		denom := b.ok + b.protocol + b.refused + b.dns + b.other
		if denom > 0 {
			v := float64(denom-b.ok) * 100 / float64(denom)
			s.FailurePct = &v
		}
		if b.unknown+b.ok+b.protocol > 0 {
			v := float64(b.unknown) * 100 / float64(b.completed)
			s.UnknownPct = &v
		}
	}
	return s
}

type summaryMsg struct {
	Sent                int               `json:"sent"`
	Pending             int               `json:"pending"`
	Completed           int               `json:"completed"`
	OK                  int               `json:"ok"`
	Timeout             int               `json:"timeout"`
	Unknown             int               `json:"unknown"`
	Refused             int               `json:"refused"`
	DNS                 int               `json:"dns"`
	Protocol            int               `json:"protocol"`
	Other               int               `json:"other"`
	Reconnects          int               `json:"reconnects"`
	ConsecutiveFailures int               `json:"consecutiveFailures"`
	RttMs               *float64          `json:"rttMs,omitempty"`
	JitterMs            *float64          `json:"jitterMs,omitempty"`
	ProbeLossPct        *float64          `json:"probeLossPct,omitempty"`
	FailurePct          *float64          `json:"failurePct,omitempty"`
	UnknownPct          *float64          `json:"unknownPct,omitempty"`
	LastNote            string            `json:"lastNote,omitempty"`
	Detail              map[string]string `json:"detail,omitempty"`
}
