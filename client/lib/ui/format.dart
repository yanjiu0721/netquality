import '../metrics/sample_book.dart';

String formatMs(double? ms) {
  if (ms == null) {
    return '—';
  }
  if (ms < 1) {
    return '${ms.toStringAsFixed(3)} ms';
  }
  if (ms < 10) {
    return '${ms.toStringAsFixed(2)} ms';
  }
  if (ms < 100) {
    return '${ms.toStringAsFixed(1)} ms';
  }
  return '${ms.toStringAsFixed(0)} ms';
}

String formatPct(double? pct) {
  if (pct == null) {
    return '—';
  }
  if (pct == 0) {
    return '0%';
  }
  if (pct < 10) {
    return '${pct.toStringAsFixed(1)}%';
  }
  return '${pct.toStringAsFixed(0)}%';
}

String visibilityLabel(String visibility) {
  switch (visibility) {
    case 'public':
      return '公开';
    case 'private':
      return '需要口令';
    default:
      return '未检查';
  }
}

String summaryLine(ProbeSummary summary) {
  if (summary.completed == 0) {
    return '还没有完成的探测';
  }
  final parts = <String>[
    '完成 ${summary.completed}',
    '成功 ${summary.ok}',
  ];
  if (summary.timeout > 0) {
    parts.add('超时 ${summary.timeout}');
  }
  if (summary.unknown > 0) {
    parts.add('无应答 ${summary.unknown}');
  }
  if (summary.refused > 0) {
    parts.add('拒绝 ${summary.refused}');
  }
  if (summary.dns > 0) {
    parts.add('域名 ${summary.dns}');
  }
  if (summary.protocol > 0) {
    parts.add('协议 ${summary.protocol}');
  }
  if (summary.other > 0) {
    parts.add('其他失败 ${summary.other}');
  }
  if (summary.reconnects > 0) {
    parts.add('重连 ${summary.reconnects}');
  }
  if (summary.consecutiveFailures > 0) {
    parts.add('连续失败 ${summary.consecutiveFailures}');
  }
  return parts.join(' · ');
}
