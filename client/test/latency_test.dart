import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/metrics/latency.dart';
import 'package:netquality/metrics/sample_book.dart';
import 'package:netquality/ui/metrics_panel.dart';

void main() {
  test('percentile ranks match the documented integer formula', () {
    expect(nearestRank95(1), 1);
    expect(nearestRank95(2), 2);
    expect(nearestRank95(4), 4);
    expect(nearestRank95(5), 5);
    expect(nearestRank95(20), 19);

    final one = LatencyStats.from([10]);
    expect(one!.min, 10);
    expect(one.mean, 10);
    expect(one.median, 10);
    expect(one.p95, 10);
    expect(one.max, 10);

    final two = LatencyStats.from([10, 30]);
    expect(two!.median, 20);
    expect(two.p95, 30);
    expect(two.mean, 20);

    final four = LatencyStats.from([1, 2, 3, 4]);
    expect(four!.median, 2.5);
    expect(four.p95, 4);
    expect(four.min, 1);
    expect(four.max, 4);

    final five = LatencyStats.from([1, 2, 3, 4, 10]);
    expect(five!.median, 3);
    expect(five.p95, 10);
    expect(five.mean, 4);
  });

  test('sample book keeps current rtt separate from the distribution', () {
    final book = SampleBook('nq-udp');
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 1));
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 2));
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 3));
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 4));
    final summary = book.summary();
    expect(summary.rttMs, 4);
    expect(summary.minRttMs, 1);
    expect(summary.maxRttMs, 4);
    expect(summary.medianRttMs, 2.5);
    expect(summary.p95RttMs, 4);
    expect(summary.meanRttMs, 2.5);
    expect(summary.latencyStats, isTrue);
    expect(summary.jitterMs, isNotNull);
  });

  test('unsupported rates stay blank instead of a false zero', () {
    final silent = SampleBook('udp-generic')
      ..add(const Outcome(status: Outcome.unknown, kind: Outcome.query));
    final lines = metricLines(
      summary: silent.summary(),
      profileId: 'udp-generic',
      elapsed: const Duration(seconds: 2),
    );
    expect(_value(lines, '超时'), '不适用');
    expect(_value(lines, '无应答（未知）'), '100%');
    expect(_value(lines, '探测无应答'), isNull);
    expect(_value(lines, '当前延迟'), '—');

    final connect = SampleBook('tcp-connect');
    final empty = metricLines(
      summary: connect.summary(),
      profileId: 'tcp-connect',
      elapsed: Duration.zero,
    );
    expect(_value(empty, '失败率'), '—');
    expect(_value(empty, '探测无应答'), isNull);

    final oldNode = ProbeSummary.fromJson({
      'sent': 1,
      'completed': 1,
      'ok': 1,
      'rttMs': 8,
      'probeLossPct': 0,
    });
    final remote = metricLines(
      summary: oldNode,
      profileId: 'nq-udp',
      elapsed: const Duration(seconds: 3),
    );
    expect(_value(remote, '当前延迟'), '8.00 ms');
    expect(_value(remote, 'P95 延迟'), '节点未提供');
    expect(_value(remote, '探测无应答'), '0%');
  });
}

String? _value(List<MetricLine> lines, String label) {
  for (final line in lines) {
    if (line.label == label) {
      return line.value;
    }
  }
  return null;
}
