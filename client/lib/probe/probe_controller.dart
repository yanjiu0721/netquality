import 'dart:async';

import 'package:flutter/foundation.dart';

import '../metrics/sample_book.dart';
import '../models/probe_profile.dart';
import '../models/session_config.dart';
import 'endpoint_picker.dart';
import 'probe_loop.dart';
import 'remote_client.dart';

class ChartSample {
  const ChartSample({required this.sec, required this.rttMs, required this.ratePct});

  final double sec;
  final double? rttMs;
  final double? ratePct;
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
    this.targetAddress,
    this.targetIsFake = false,
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
  final String? targetAddress;
  final bool targetIsFake;

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
    String? targetAddress,
    bool? targetIsFake,
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
      targetAddress: targetAddress ?? this.targetAddress,
      targetIsFake: targetIsFake ?? this.targetIsFake,
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

  Future<void> start(SessionConfig config, {required String nodeToken, required String echoToken}) async {
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
    final generation = ++_token;
    _clock
      ..reset()
      ..start();
    final source = config.remote ? (config.node?.name ?? '远程节点') : '本机';
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
    );
    notifyListeners();
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
          cancelled: cancelled,
        );
      } else {
        final loop = ProbeLoop(
          onEndpoint: (address) {
            if (generation != _token) {
              return;
            }
            view = view.copyWith(
              targetAddress: address.address,
              targetIsFake: isClashFakeIp(address),
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
      if (generation == _token) {
        view = view.copyWith(running: false, phase: '已停止');
        notifyListeners();
      }
    } on RemoteException catch (error) {
      if (generation == _token) {
        view = view.copyWith(running: false, phase: '出错', banner: error.message);
        notifyListeners();
      }
    } on Object {
      if (generation == _token) {
        view = view.copyWith(running: false, phase: '出错', banner: '探测中断');
        notifyListeners();
      }
    } finally {
      if (generation == _token) {
        _local = null;
        _remote = null;
      }
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
      view = view.copyWith(running: false, phase: '已停止');
      notifyListeners();
    }
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
    view = view.copyWith(
      phase: phaseFor(sample.status),
      note: sample.note,
      detail: sample.detail.isEmpty ? sample.summary.detail : sample.detail,
      summary: sample.summary,
      samples: samples,
      clearBanner: true,
    );
    notifyListeners();
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
