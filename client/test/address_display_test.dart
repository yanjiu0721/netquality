import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/content/release_history.dart';
import 'package:netquality/metrics/sample_book.dart';
import 'package:netquality/ui/address_text.dart';
import 'package:netquality/ui/chart_selection.dart';
import 'package:netquality/version.dart';

void main() {
  test('resolved addresses are not shown as the address in use', () {
    const resolved = [
      ResolvedAddress(address: '2001:db8::1', family: 'IPv6'),
      ResolvedAddress(address: '203.0.113.5', family: 'IPv4'),
    ];
    final onlyResolved = describeAddress(resolved: resolved);
    expect(onlyResolved.used, isNull);
    expect(onlyResolved.resolved, contains('解析到'));
    expect(onlyResolved.resolved, contains('2001:db8::1'));
    expect(onlyResolved.resolved, isNot(contains('实际地址')));

    final used = describeAddress(
      resolved: resolved,
      usedAddress: '203.0.113.5',
      usedFamily: 'IPv4',
      fallbackText: '已改用 IPv4',
    );
    expect(used.used, '实际地址 203.0.113.5（IPv4）');
    expect(used.resolved, contains('2001:db8::1'));
    expect(used.fallback, '已改用 IPv4');

    final oldNode = describeAddress(
      resolved: const [],
      addressUnreported: true,
    );
    expect(oldNode.used, isNull);
    expect(oldNode.unreported, '节点没有报告实际使用的地址');

    final missing = ProbeSample.fromJson({
      'seq': 1,
      'status': 'ok',
      'kind': 'probe',
      'rttMs': 3,
      'summary': {'sent': 1, 'ok': 1},
    });
    expect(missing.detail['address'], isNull);
    final parsed = readResolvedList({
      'resolved': [
        {'address': '2001:db8::1', 'family': 'IPv6'},
      ],
    });
    expect(parsed.single.address, '2001:db8::1');
    expect(readResolvedList({'jobId': 'abc'}), isEmpty);
  });

  test('a pinned chart point stays put until it scrolls off or the session changes', () {
    const first = ChartSelection(sec: 1.5, sessionId: 3);
    final kept = nextChartSelection(
      current: first,
      sessionId: 3,
      sampleSecs: [1.5, 2.5, 3.5],
    );
    expect(kept, same(first));

    final moved = nextChartSelection(
      current: first,
      sessionId: 3,
      sampleSecs: [1.5, 2.5, 3.5],
      tappedSec: 2.4,
    );
    expect(moved!.sec, 2.5);
    expect(moved.sessionId, 3);

    expect(
      nextChartSelection(current: moved, sessionId: 4, sampleSecs: [0.2, 0.4]),
      isNull,
    );
    expect(
      nextChartSelection(current: first, sessionId: 3, sampleSecs: [2.5, 3.5]),
      isNull,
    );
    expect(
      nextChartSelection(current: first, sessionId: 3, sampleSecs: const []),
      isNull,
    );
  });

  test('history only lists the real tag and this version', () {
    expect(appVersion, '1.1.3');
    expect(appBuild, 6);
    expect(appAttribution, '言灸');
    expect(releaseHistory.map((entry) => entry.version), [
      '1.1.3',
      '1.1.2',
      '1.1.1',
    ]);
    expect(releaseHistory.last.published, '2026-11-09');
    expect(releaseHistory.last.source, contains('v1.1.1'));
    expect(releaseHistoryNote, contains('不写成另一个版本'));
    for (final entry in releaseHistory) {
      expect(entry.version, isNot('1.1.0'));
      expect(entry.version, isNot('1.0.0'));
    }
  });
}
