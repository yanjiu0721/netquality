class Outcome {
  const Outcome({
    required this.status,
    required this.kind,
    this.rttMs,
    this.note = '',
    this.detail = const {},
    this.reconnect = false,
  });

  final String status;
  final String kind;
  final double? rttMs;
  final String note;
  final Map<String, String> detail;
  final bool reconnect;

  static const ok = 'ok';
  static const timeout = 'timeout';
  static const unknown = 'unknown';
  static const refused = 'refused';
  static const dns = 'dns';
  static const protocol = 'protocol';
  static const error = 'error';

  static const connect = 'connect';
  static const probe = 'probe';
  static const query = 'query';
}

class ProbeSummary {
  const ProbeSummary({
    required this.sent,
    required this.completed,
    required this.ok,
    required this.timeout,
    required this.unknown,
    required this.refused,
    required this.dns,
    required this.protocol,
    required this.other,
    required this.reconnects,
    required this.consecutiveFailures,
    required this.rttMs,
    required this.jitterMs,
    required this.probeLossPct,
    required this.failurePct,
    required this.unknownPct,
    required this.lastNote,
    required this.detail,
  });

  final int sent;
  final int completed;
  final int ok;
  final int timeout;
  final int unknown;
  final int refused;
  final int dns;
  final int protocol;
  final int other;
  final int reconnects;
  final int consecutiveFailures;
  final double? rttMs;
  final double? jitterMs;
  final double? probeLossPct;
  final double? failurePct;
  final double? unknownPct;
  final String lastNote;
  final Map<String, String> detail;

  static const empty = ProbeSummary(
    sent: 0,
    completed: 0,
    ok: 0,
    timeout: 0,
    unknown: 0,
    refused: 0,
    dns: 0,
    protocol: 0,
    other: 0,
    reconnects: 0,
    consecutiveFailures: 0,
    rttMs: null,
    jitterMs: null,
    probeLossPct: null,
    failurePct: null,
    unknownPct: null,
    lastNote: '',
    detail: {},
  );

  factory ProbeSummary.fromJson(Map<String, dynamic> json) {
    return ProbeSummary(
      sent: _int(json['sent']),
      completed: _int(json['completed']),
      ok: _int(json['ok']),
      timeout: _int(json['timeout']),
      unknown: _int(json['unknown']),
      refused: _int(json['refused']),
      dns: _int(json['dns']),
      protocol: _int(json['protocol']),
      other: _int(json['other']),
      reconnects: _int(json['reconnects']),
      consecutiveFailures: _int(json['consecutiveFailures']),
      rttMs: _double(json['rttMs']),
      jitterMs: _double(json['jitterMs']),
      probeLossPct: _double(json['probeLossPct']),
      failurePct: _double(json['failurePct']),
      unknownPct: _double(json['unknownPct']),
      lastNote: json['lastNote'] is String ? json['lastNote'] as String : '',
      detail: _detail(json['detail']),
    );
  }
}

class ProbeSample {
  const ProbeSample({
    required this.seq,
    required this.status,
    required this.kind,
    required this.rttMs,
    required this.jitterMs,
    required this.note,
    required this.detail,
    required this.summary,
  });

  final int seq;
  final String status;
  final String kind;
  final double? rttMs;
  final double? jitterMs;
  final String note;
  final Map<String, String> detail;
  final ProbeSummary summary;

  factory ProbeSample.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] is Map
        ? ProbeSummary.fromJson(Map<String, dynamic>.from(json['summary'] as Map))
        : ProbeSummary.empty;
    return ProbeSample(
      seq: _int(json['seq']),
      status: json['status'] is String ? json['status'] as String : '',
      kind: json['kind'] is String ? json['kind'] as String : '',
      rttMs: _double(json['rttMs']),
      jitterMs: _double(json['jitterMs']),
      note: json['note'] is String ? json['note'] as String : '',
      detail: _detail(json['detail']),
      summary: summary,
    );
  }
}

class SampleBook {
  SampleBook(this.profile);

  final String profile;
  int sent = 0;
  int completed = 0;
  int ok = 0;
  int timeout = 0;
  int unknown = 0;
  int refused = 0;
  int dns = 0;
  int protocol = 0;
  int other = 0;
  int reconnects = 0;
  int consecutive = 0;
  double? lastRttMs;
  double jitterMs = 0;
  bool _hasJitter = false;
  double _lastTransit = 0;
  String lastNote = '';
  Map<String, String> detail = {};

  void add(Outcome outcome) {
    sent += 1;
    completed += 1;
    if (outcome.reconnect) {
      reconnects += 1;
    }
    if (outcome.note.isNotEmpty) {
      lastNote = outcome.note;
    }
    if (outcome.detail.isNotEmpty) {
      detail = {...detail, ...outcome.detail};
    }
    switch (outcome.status) {
      case Outcome.ok:
        ok += 1;
        consecutive = 0;
        final rtt = outcome.rttMs;
        if (rtt != null) {
          lastRttMs = rtt;
          if (_hasJitter) {
            final delta = (rtt - _lastTransit).abs();
            jitterMs += (delta - jitterMs) / 16;
          }
          _lastTransit = rtt;
          _hasJitter = true;
        }
      case Outcome.timeout:
        if (outcome.kind == Outcome.probe) {
          timeout += 1;
        } else {
          other += 1;
        }
        consecutive += 1;
      case Outcome.unknown:
        unknown += 1;
      case Outcome.refused:
        refused += 1;
        consecutive += 1;
      case Outcome.dns:
        dns += 1;
        consecutive += 1;
      case Outcome.protocol:
        protocol += 1;
        consecutive += 1;
      default:
        other += 1;
        consecutive += 1;
    }
  }

  ProbeSummary summary() {
    double? probeLoss;
    double? failure;
    double? unknownPct;
    if (completed > 0) {
      if (profile == 'nq-tcp' || profile == 'nq-udp') {
        final denom = timeout + ok;
        if (denom > 0) {
          probeLoss = timeout * 100 / denom;
        }
      } else if (profile == 'tcp-connect' || profile == 'minecraft-java') {
        final denom = ok + timeout + refused + dns + protocol + other;
        if (denom > 0) {
          failure = (denom - ok) * 100 / denom;
        }
      } else {
        final denom = ok + protocol + refused + dns + other;
        if (denom > 0) {
          failure = (denom - ok) * 100 / denom;
        }
        final known = unknown + ok + protocol;
        if (known > 0) {
          unknownPct = unknown * 100 / completed;
        }
      }
    }
    return ProbeSummary(
      sent: sent,
      completed: completed,
      ok: ok,
      timeout: timeout,
      unknown: unknown,
      refused: refused,
      dns: dns,
      protocol: protocol,
      other: other,
      reconnects: reconnects,
      consecutiveFailures: consecutive,
      rttMs: lastRttMs,
      jitterMs: _hasJitter ? jitterMs : null,
      probeLossPct: probeLoss,
      failurePct: failure,
      unknownPct: unknownPct,
      lastNote: lastNote,
      detail: detail,
    );
  }

  ProbeSample sample(int seq, Outcome outcome) {
    final folded = summary();
    return ProbeSample(
      seq: seq,
      status: outcome.status,
      kind: outcome.kind,
      rttMs: outcome.rttMs,
      jitterMs: outcome.status == Outcome.ok ? folded.jitterMs : null,
      note: outcome.note,
      detail: outcome.detail,
      summary: folded,
    );
  }
}

double? chartRate(String profile, ProbeSummary summary) {
  switch (profile) {
    case 'nq-tcp':
    case 'nq-udp':
      return summary.probeLossPct;
    case 'tcp-connect':
    case 'minecraft-java':
      return summary.failurePct;
    default:
      return summary.unknownPct;
  }
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
}

double? _double(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return null;
}

Map<String, String> _detail(Object? value) {
  if (value is! Map) {
    return const {};
  }
  final out = <String, String>{};
  value.forEach((key, item) {
    if (key is String && item is String) {
      out[key] = item;
    }
  });
  return out;
}
