import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/metrics/sample_book.dart';
import 'package:netquality/metrics/selection_ledger.dart';

void main() {
  const v6 = Outcome(
    status: Outcome.timeout,
    kind: Outcome.probe,
    note: '未收到回显',
    detail: {'address': '2001:db8::1', 'family': 'IPv6'},
  );
  const v4ok = Outcome(
    status: Outcome.ok,
    kind: Outcome.probe,
    rttMs: 5,
    note: '收到回显',
    detail: {'address': '203.0.113.5', 'family': 'IPv4'},
  );
  const v4timeout = Outcome(
    status: Outcome.timeout,
    kind: Outcome.probe,
    note: '未收到回显',
    detail: {'address': '203.0.113.5', 'family': 'IPv4'},
  );

  test('ipv6 miss then ipv4 success is not formal loss', () {
    final ledger = SelectionLedger(2);
    expect(ledger.take(v6, responded: false).commit, isEmpty);
    final decision = ledger.take(v4ok, responded: true);
    expect(decision.skipped, 1);
    expect(decision.commit.single.selectionSkipped, 1);
    expect(decision.commit.single.detail['fallback'], contains('2001:db8::1'));
    expect(decision.commit.single.detail['fallback'], contains('203.0.113.5'));
    expect(decision.commit.single.detail['fallback'], contains('没有计入'));
    final book = SampleBook('nq-udp');
    book.add(decision.commit.single);
    final summary = book.summary();
    expect(summary.sent, 1);
    expect(summary.ok, 1);
    expect(summary.timeout, 0);
    expect(summary.probeLossPct, 0);
    expect(summary.selectionSkipped, 1);
  });

  test('every candidate failing is loss, not a false zero', () {
    final ledger = SelectionLedger(2);
    expect(ledger.take(v6, responded: false).commit, isEmpty);
    final decision = ledger.take(v4timeout, responded: false);
    expect(decision.commit, hasLength(2));
    final book = SampleBook('nq-udp');
    for (final outcome in decision.commit) {
      book.add(outcome);
    }
    final summary = book.summary();
    expect(summary.ok, 0);
    expect(summary.sent, 2);
    expect(summary.timeout, 2);
    expect(summary.probeLossPct, 100);
    expect(summary.selectionSkipped, 0);
  });

  test('timeouts after an address is selected still count', () {
    final ledger = SelectionLedger(2);
    final first = ledger.take(v4ok, responded: true);
    expect(ledger.measuring, isTrue);
    final again = ledger.take(v4timeout, responded: false);
    expect(again.commit, hasLength(1));
    final book = SampleBook('nq-udp');
    book.add(first.commit.single);
    book.add(again.commit.single);
    expect(book.summary().probeLossPct, 50);
    expect(book.summary().sent, 2);
  });

  test('one address never hides a failure', () {
    final ledger = SelectionLedger(1);
    final decision = ledger.take(v4timeout, responded: false);
    expect(decision.commit, hasLength(1));
    final book = SampleBook('nq-tcp');
    book.add(decision.commit.single);
    expect(book.summary().probeLossPct, 100);
  });

  test('a stopped in-flight attempt is not recorded', () {
    expect(
      countsAfterStop(
        const Outcome(
          status: Outcome.timeout,
          kind: Outcome.probe,
          note: '已停止',
        ),
        cancelled: false,
      ),
      isFalse,
    );
    expect(
      countsAfterStop(
        const Outcome(status: Outcome.timeout, kind: Outcome.probe),
        cancelled: true,
      ),
      isFalse,
    );
    expect(
      countsAfterStop(
        const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 1),
        cancelled: false,
      ),
      isTrue,
    );
    expect(countsAfterStop(null, cancelled: false), isFalse);
  });

  test(
    'leaving a measured address does not drop the failure that caused it',
    () {
      final ledger = SelectionLedger(2);
      ledger.take(v4ok, responded: true);
      final miss = ledger.take(v4timeout, responded: false);
      expect(miss.commit, hasLength(1));
      ledger.endMeasurement();
      expect(ledger.measuring, isFalse);
      final held = ledger.take(v6, responded: false);
      expect(held.commit, isEmpty);
      final recovered = ledger.take(v4ok, responded: true);
      expect(recovered.skipped, 1);
      final book = SampleBook('nq-udp');
      book.add(v4ok);
      book.add(miss.commit.single);
      book.add(recovered.commit.single);
      expect(book.summary().sent, 3);
      expect(book.summary().timeout, 1);
      expect(book.summary().probeLossPct, closeTo(100 / 3, 0.0001));
    },
  );
}
