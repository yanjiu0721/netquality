// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../metrics/sample_book.dart';
import '../models/probe_profile.dart';
import '../models/session_config.dart';
import '../ui/address_text.dart';
import 'endpoint_picker.dart';
import 'probe_loop.dart';
import 'remote_client.dart';

class ChartSample {
  const ChartSample({
    required this.sec,
    required this.rttMs,
    required this.ratePct,
  });

  final double sec;
  final double? rttMs;
  final double? ratePct;
}

class SessionReport {
  const SessionReport({
    required this.startedAt,
    required this.endedAt,
    required this.elapsed,
    required this.target,
    required this.profileLabel,
    required this.sourceLabel,
    required this.profileId,
    required this.summary,
    required this.rateLabel,
    required this.resolved,
    required this.usedAddress,
    required this.usedFamily,
    required this.fallbackText,
    required this.addressUnreported,
    required this.usedIsFake,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final Duration elapsed;
  final String target;
  final String profileLabel;
  final String sourceLabel;
  final String profileId;
  final ProbeSummary summary;
  final String rateLabel;
  final List<ResolvedAddress> resolved;
  final String? usedAddress;
  final String? usedFamily;
  final String fallbackText;
  final bool addressUnreported;
  final bool usedIsFake;
}

class ProbeView {
  const ProbeView({
    required this.running,
    required this.phase,
    required this.banner,
    required this.note,
    required this.detail,
    required this.summary,
    required this.samples,
    required this.rateLabel,
    required this.sourceLabel,
    required this.sessionId,
    this.profileId = '',
    required this.elapsed,
    this.targetHost = '',
    this.profileLabel = '',
    this.tryingAddress,
    this.tryingFamily,
    this.usedAddress,
    this.usedFamily,
    this.usedIsFake = false,
    this.resolved = const [],
    this.fallbackText = '',
    this.addressUnreported = false,
    this.report,
    this.startedAt,
    this.endedAt,
  });

  static const initial = ProbeView(
    running: false,
    phase: '未开始',
    banner: null,
    note: '',
    detail: {},
    summary: ProbeSummary.empty,
    samples: [],
    rateLabel: '探测无应答',
    sourceLabel: '本机',
    sessionId: 0,
    elapsed: Duration.zero,
  );

  final bool running;
  final String phase;
  final String? banner;
  final String note;
  final Map<String, String> detail;
  final ProbeSummary summary;
  final List<ChartSample> samples;
  final String rateLabel;
  final String sourceLabel;
  final int sessionId;
  final String profileId;
  final Duration elapsed;
  final String targetHost;
  final String profileLabel;
  final String? tryingAddress;
  final String? tryingFamily;
  final String? usedAddress;
  final String? usedFamily;
  final bool usedIsFake;
  final List<ResolvedAddress> resolved;
  final String fallbackText;
  final bool addressUnreported;
  final SessionReport? report;
  final DateTime? startedAt;
  final DateTime? endedAt;

  ProbeView copyWith({
    bool? running,
    String? phase,
    String? banner,
    bool clearBanner = false,
    String? note,
    Map<String, String>? detail,
    ProbeSummary? summary,
    List<ChartSample>? samples,
    String? rateLabel,
    String? sourceLabel,
    int? sessionId,
    String? profileId,
    Duration? elapsed,
    String? targetHost,
    String? profileLabel,
    String? tryingAddress,
    String? tryingFamily,
    bool clearTrying = false,
    String? usedAddress,
    String? usedFamily,
    bool? usedIsFake,
    List<ResolvedAddress>? resolved,
    String? fallbackText,
    bool? addressUnreported,
    SessionReport? report,
    bool clearReport = false,
    DateTime? startedAt,
    DateTime? endedAt,
  }) {
    return ProbeView(
      running: running ?? this.running,
      phase: phase ?? this.phase,
      banner: clearBanner ? null : banner ?? this.banner,
      note: note ?? this.note,
      detail: detail ?? this.detail,
      summary: summary ?? this.summary,
      samples: samples ?? this.samples,
      rateLabel: rateLabel ?? this.rateLabel,
      sourceLabel: sourceLabel ?? this.sourceLabel,
      sessionId: sessionId ?? this.sessionId,
      profileId: profileId ?? this.profileId,
      elapsed: elapsed ?? this.elapsed,
      targetHost: targetHost ?? this.targetHost,
      profileLabel: profileLabel ?? this.profileLabel,
      tryingAddress: clearTrying ? null : tryingAddress ?? this.tryingAddress,
      tryingFamily: clearTrying ? null : tryingFamily ?? this.tryingFamily,
      usedAddress: usedAddress ?? this.usedAddress,
      usedFamily: usedFamily ?? this.usedFamily,
      usedIsFake: usedIsFake ?? this.usedIsFake,
      resolved: resolved ?? this.resolved,
      fallbackText: fallbackText ?? this.fallbackText,
      addressUnreported: addressUnreported ?? this.addressUnreported,
      report: clearReport ? null : report ?? this.report,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
    );
  }
}

class ProbeController extends ChangeNotifier {
  ProbeView view = ProbeView.initial;
  final Stopwatch _clock = Stopwatch();
  ProbeLoop? _local;
  RemoteProbe? _remote;
  String _nodeToken = '';
  var _token = 0;
  var _session = 0;
  var _busy = false;
  var _remoteMode = false;
  DateTime? _startedAt;
  Timer? _tick;

  Future<void> start(
    SessionConfig config, {
    required String nodeToken,
    required String echoToken,
  }) async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      final problem = config.validate();
      if (problem != null) {
        view = view.copyWith(banner: problem, phase: '无法开始');
        notifyListeners();
        return;
      }
      final echoProblem = _echoProblem(config.profileId, echoToken);
      if (echoProblem != null) {
        view = view.copyWith(banner: echoProblem, phase: '无法开始');
        notifyListeners();
        return;
      }
      await stop();
      _nodeToken = nodeToken;
      _remoteMode = config.remote;
      final generation = ++_token;
      final session = ++_session;
      _startedAt = DateTime.now();
      _clock
        ..reset()
        ..start();
      final source = config.remote ? (config.node?.name ?? '远程节点') : '本机';
      final profile = ProbeProfile.byId(config.profileId);
      view = ProbeView(
        running: true,
        phase: '探测中',
        banner: null,
        note: config.remote ? '正在让节点向目标发包' : '正在从本机向目标发包',
        detail: const {},
        summary: ProbeSummary.empty,
        samples: const [],
        rateLabel: rateLabelFor(config.profileId),
        sourceLabel: source,
        sessionId: session,
        profileId: config.profileId,
        elapsed: Duration.zero,
        targetHost: '${config.host.trim()}:${config.port}',
        profileLabel: profile.label,
        startedAt: _startedAt,
      );
      notifyListeners();
      _armTick(generation);
      bool cancelled() => generation != _token;
      try {
        if (config.remote) {
          final remote = RemoteProbe();
          _remote = remote;
          await remote.run(
            baseUrl: config.node!.baseUrl,
            nodeToken: nodeToken,
            body: ProbeBody(
              target: config.host.trim(),
              port: config.port,
              profile: config.profileId,
              intervalMs: config.intervalMs,
              timeoutMs: config.timeoutMs,
              durationSec: config.durationSec,
              packetSize: config.packetSize,
              echoToken: echoToken,
              dnsName: config.dnsName.trim(),
              payloadHex: config.payloadHex.trim(),
              expectHex: config.expectHex.trim(),
            ),
            onSample: (sample) => _accept(generation, sample),
            onResolved: (resolved) {
              if (generation != _token) {
                return;
              }
              view = view.copyWith(resolved: resolved);
              notifyListeners();
            },
            cancelled: cancelled,
          );
        } else {
          final loop = ProbeLoop(
            onEndpoint: (address) {
              if (generation != _token) {
                return;
              }
              view = view.copyWith(
                tryingAddress: address.address,
                tryingFamily: addressFamily(address),
              );
              notifyListeners();
            },
            onResolved: (addresses) {
              if (generation != _token) {
                return;
              }
              view = view.copyWith(
                resolved: [
                  for (final address in addresses)
                    ResolvedAddress(
                      address: address.address,
                      family: addressFamily(address),
                    ),
                ],
              );
              notifyListeners();
            },
          );
          _local = loop;
          await loop.run(
            request: ProbeRequest(
              host: config.host.trim(),
              port: config.port,
              profileId: config.profileId,
              interval: Duration(milliseconds: config.intervalMs),
              timeout: Duration(milliseconds: config.timeoutMs),
              packetSize: config.packetSize,
              echoToken: echoToken,
              dnsName: config.dnsName.trim(),
              payloadHex: config.payloadHex.trim(),
              expectHex: config.expectHex.trim(),
            ),
            onSample: (sample) => _accept(generation, sample),
            cancelled: cancelled,
          );
        }
        _finish(generation, '已停止');
      } on RemoteException catch (error) {
        _finish(generation, '出错', banner: error.message);
      } on Object {
        _finish(generation, '出错', banner: '探测中断');
      } finally {
        if (generation == _token) {
          _local = null;
          _remote = null;
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> stop() async {
    _token += 1;
    final local = _local;
    final remote = _remote;
    _local = null;
    _remote = null;
    if (local != null) {
      await local.close();
    }
    if (remote != null) {
      await remote.stop(_nodeToken);
      _nodeToken = '';
    }
    if (view.running) {
      _clock.stop();
      _tick?.cancel();
      final ended = DateTime.now();
      view = view.copyWith(
        running: false,
        phase: '已停止',
        elapsed: _clock.elapsed,
        endedAt: ended,
        report: _snapshot(ended),
      );
      notifyListeners();
    }
  }

  void _finish(int generation, String phase, {String? banner}) {
    if (generation != _token || !view.running) {
      return;
    }
    _clock.stop();
    _tick?.cancel();
    final ended = DateTime.now();
    view = view.copyWith(
      running: false,
      phase: phase,
      banner: banner,
      elapsed: _clock.elapsed,
      endedAt: ended,
      report: _snapshot(ended),
    );
    notifyListeners();
  }

  SessionReport? _snapshot(DateTime ended) {
    final started = _startedAt;
    if (started == null) {
      return null;
    }
    return SessionReport(
      startedAt: started,
      endedAt: ended,
      elapsed: _clock.elapsed,
      target: view.targetHost,
      profileLabel: view.profileLabel,
      sourceLabel: view.sourceLabel,
      profileId: view.profileId,
      summary: view.summary,
      rateLabel: view.rateLabel,
      resolved: view.resolved,
      usedAddress: view.usedAddress,
      usedFamily: view.usedFamily,
      fallbackText: view.fallbackText,
      addressUnreported: view.addressUnreported,
      usedIsFake: view.usedIsFake,
    );
  }

  void _armTick(int generation) {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (generation != _token || !view.running) {
        return;
      }
      view = view.copyWith(elapsed: _clock.elapsed);
      notifyListeners();
    });
  }

  void _accept(int generation, ProbeSample sample) {
    if (generation != _token) {
      return;
    }
    final samples = [...view.samples];
    if (samples.length >= 180) {
      samples.removeAt(0);
    }
    final double? rate;
    switch (view.rateLabel) {
      case '探测无应答':
        rate = sample.summary.probeLossPct;
      case '失败率':
        rate = sample.summary.failurePct;
      default:
        rate = sample.summary.unknownPct;
    }
    samples.add(
      ChartSample(
        sec: _clock.elapsedMilliseconds / 1000,
        rttMs: sample.status == Outcome.ok ? sample.rttMs : null,
        ratePct: rate,
      ),
    );
    final reported = sample.detail['address'];
    final hasAddress = reported != null && reported.isNotEmpty;
    final fallback = sample.detail['fallback'];
    final parsed = hasAddress ? InternetAddress.tryParse(reported) : null;
    final family = hasAddress
        ? ((sample.detail['family'] != null &&
                  sample.detail['family']!.isNotEmpty)
              ? sample.detail['family']
              : familyOfAddress(reported))
        : null;
    view = view.copyWith(
      phase: phaseFor(sample.status),
      note: sample.note,
      detail: sample.detail.isEmpty ? sample.summary.detail : sample.detail,
      summary: sample.summary,
      samples: samples,
      clearBanner: true,
      elapsed: _clock.elapsed,
      usedAddress: hasAddress ? reported : view.usedAddress,
      usedFamily: hasAddress ? family : view.usedFamily,
      usedIsFake: hasAddress
          ? parsed != null && isClashFakeIp(parsed)
          : view.usedIsFake,
      clearTrying: hasAddress || (fallback != null && fallback.isNotEmpty),
      fallbackText: (fallback != null && fallback.isNotEmpty) ? fallback : null,
      addressUnreported: _remoteMode && !hasAddress,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

String? _echoProblem(String profileId, String echoToken) {
  if (profileId != 'nq-tcp' && profileId != 'nq-udp') {
    return null;
  }
  if (echoToken.length > 32) {
    return '目标回显口令最长 32 字节';
  }
  return null;
}

String phaseFor(String status) {
  switch (status) {
    case Outcome.ok:
      return '有应答';
    case Outcome.timeout:
      return '超时';
    case Outcome.unknown:
      return '无应答';
    case Outcome.refused:
      return '被拒绝';
    case Outcome.dns:
      return '域名失败';
    case Outcome.protocol:
      return '协议不符';
    default:
      return '出错';
  }
}
