// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../metrics/sample_book.dart';
import '../probe/endpoint_picker.dart';
import '../probe/probe_controller.dart';
import 'address_text.dart';
import 'format.dart';
import 'quality_charts.dart';

class MetricLine {
  const MetricLine(this.label, this.value, {this.detail});

  final String label;
  final String value;
  final String? detail;
}

/// Rows use the same summary the live view and the stopped session share.
/// A metric that this profile does not measure is marked unsupported instead
/// of being shown as zero.
List<MetricLine> metricLines({
  required ProbeSummary summary,
  required String profileId,
  required Duration elapsed,
}) {
  final lines = <MetricLine>[
    MetricLine(
      '已发送',
      '${summary.sent}',
      detail: summary.selectionSkipped > 0
          ? '正式结果 ${summary.sent} 次。另有 ${summary.selectionSkipped} 次选址失败未计入。'
          : '只计已经计入正式结果的次数，不含还在途中的探测。',
    ),
    MetricLine('已收到', '${summary.ok}', detail: '成功收到应答，或成功连通的次数。'),
    _timeoutLine(summary, profileId),
    _rateLine(summary, profileId),
    _latency('当前延迟', summary.rttMs, summary, recent: true),
    _latency('最小延迟', summary.minRttMs, summary),
    _latency('平均延迟', summary.meanRttMs, summary),
    _latency('中位延迟', summary.medianRttMs, summary),
    _latency('P95 延迟', summary.p95RttMs, summary),
    _latency('最大延迟', summary.maxRttMs, summary),
    MetricLine(
      '抖动',
      summary.jitterMs == null ? '—' : formatMs(summary.jitterMs),
      detail: 'RFC 3550：J = J + (|D| − J) / 16。D 是相邻两次成功往返时间之差。只有一次成功时 J 为 0。',
    ),
    MetricLine(
      '用时',
      formatDuration(elapsed),
      detail: '从这次探测开始到现在或到停止的墙钟时间，不是往返时间相加。',
    ),
  ];
  return lines;
}

MetricLine _timeoutLine(ProbeSummary summary, String profileId) {
  switch (profileId) {
    case 'nq-tcp':
    case 'nq-udp':
      return MetricLine(
        '超时',
        '${summary.timeout}',
        detail: '已经写出回显帧、在超时前没有对上序号的次数。连接失败另计，不在这里。',
      );
    case 'tcp-connect':
    case 'minecraft-java':
      return const MetricLine('超时', '不适用', detail: '这种探测把连不上记为失败，不单独叫探测超时。');
    case 'http':
      return const MetricLine(
        '超时',
        '不适用',
        detail: 'HTTP 把连不上记为失败。已经收到的 4xx 和 5xx 是状态码，不是丢包，也不算进超时。',
      );
    default:
      return MetricLine(
        '超时',
        '不适用',
        detail: '没有协议应答时记为无应答 ${summary.unknown} 次，不能据此断定丢包。',
      );
  }
}

MetricLine _rateLine(ProbeSummary summary, String profileId) {
  switch (profileId) {
    case 'nq-tcp':
    case 'nq-udp':
      final denom = summary.timeout + summary.ok;
      return MetricLine(
        '探测无应答',
        formatPct(summary.probeLossPct),
        detail: denom == 0
            ? '还没有完成的回显尝试，所以不显示 0%。'
            : '超时 ÷（超时 + 成功）= ${summary.timeout} ÷ $denom。连接失败不在分母里。',
      );
    case 'tcp-connect':
    case 'minecraft-java':
      return MetricLine(
        '失败率',
        formatPct(summary.failurePct),
        detail: '未成功的正式尝试 ÷ 已完成的正式尝试。这不是物理丢包。',
      );
    case 'http':
      return MetricLine(
        '失败率',
        formatPct(summary.failurePct),
        detail: '连不上或协议不对才算失败。收到 HTTP 响应就算成功，4xx 和 5xx 只显示状态码，不叫丢包。曲线上的延迟是这一次的总时间。',
      );
    default:
      return MetricLine(
        '无应答（未知）',
        formatPct(summary.unknownPct),
        detail: '无应答 ÷ 已完成。沉默不是丢包；明确的协议错误、拒绝和域名失败另看失败次数。',
      );
  }
}

MetricLine _latency(
  String label,
  double? value,
  ProbeSummary summary, {
  bool recent = false,
}) {
  if (!summary.latencyStats && summary.ok > 0 && !recent) {
    return MetricLine(label, '节点未提供', detail: '这份结果来自没有上报延迟分布的节点。当前延迟仍然可用。');
  }
  return MetricLine(
    label,
    formatMs(value),
    detail: recent ? '最近一次成功的往返时间。没有成功时为 —。' : '只统计成功样本。没有成功时为 —。',
  );
}

String formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 0) {
    return '—';
  }
  if (ms < 1000) {
    return '$ms 毫秒';
  }
  final seconds = ms / 1000;
  if (seconds < 60) {
    return '${seconds.toStringAsFixed(1)} 秒';
  }
  final minutes = duration.inMinutes;
  final rest = duration.inSeconds % 60;
  return '$minutes 分 $rest 秒';
}

String formatClock(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class MetricsPanel extends StatelessWidget {
  const MetricsPanel({
    super.key,
    required this.summary,
    required this.profileId,
    required this.elapsed,
  });

  final ProbeSummary summary;
  final String profileId;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final lines = metricLines(
      summary: summary,
      profileId: profileId,
      elapsed: elapsed,
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final line in lines)
          Tooltip(
            message: line.detail ?? '',
            child: _chip('${line.label} ${line.value}'),
          ),
      ],
    );
  }
}

class SessionSummaryCard extends StatelessWidget {
  const SessionSummaryCard({
    super.key,
    required this.report,
    required this.profileId,
  });

  final SessionReport report;
  final String profileId;

  @override
  Widget build(BuildContext context) {
    final address = describeAddress(
      resolved: report.resolved,
      usedAddress: report.usedAddress,
      usedFamily: report.usedFamily,
      fallbackText: report.fallbackText,
      addressUnreported: report.addressUnreported,
      usedIsFake: report.usedIsFake,
    );
    return _panel(
      title: '本次结果',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('开始 ${formatClock(report.startedAt)}'),
          Text('结束 ${formatClock(report.endedAt)}'),
          Text('用时 ${formatDuration(report.elapsed)}'),
          Text('目标 ${report.target}'),
          Text('类型 ${report.profileLabel}'),
          Text('来源 ${report.sourceLabel}'),
          if (address.used != null) Text(address.used!),
          if (address.resolved != null) Text(address.resolved!),
          if (address.unreported != null) Text(address.unreported!),
          if (address.fallback != null) Text(address.fallback!),
          if (address.fake)
            const Text(
              clashFakeIpNote,
              style: TextStyle(color: Color(0xFF9A3412)),
            ),
          const SizedBox(height: 8),
          MetricsPanel(
            summary: report.summary,
            profileId: profileId,
            elapsed: report.elapsed,
          ),
          const SizedBox(height: 8),
          Text(
            summaryLine(report.summary),
            style: const TextStyle(color: muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

Widget _panel({required String title, required Widget child}) {
  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: line),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, color: ink),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

Widget _chip(String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFE7EEF5),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12, color: ink)),
  );
}
