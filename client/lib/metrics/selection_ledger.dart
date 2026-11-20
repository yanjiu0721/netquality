// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'sample_book.dart';

/// A candidate "responded" when the address itself answered: success, a
/// protocol mismatch, or an explicit refusal. Silence, timeout and a
/// connect error are not a response, so another address may be tried.
bool selectionResponded(Outcome outcome) {
  switch (outcome.status) {
    case Outcome.ok:
    case Outcome.protocol:
    case Outcome.refused:
      return true;
    default:
      return false;
  }
}

class SelectionDecision {
  const SelectionDecision({required this.commit, this.skipped = 0});

  final List<Outcome> commit;
  final int skipped;
}

/// Separates address selection from measured probes.
///
/// Before any candidate has responded, failures are held. A later response
/// drops those held failures: they are reported as a fallback diagnostic and
/// are not added to sent, timeout or loss. If every candidate fails in the
/// round, the held failures are committed, so the session cannot show a
/// false 0% success. After a response, further failures are committed
/// immediately. [endMeasurement] is called when the picker leaves the
/// address that was being measured; the failure that caused the leave has
/// already been committed.
class SelectionLedger {
  SelectionLedger(this.candidateCount);

  final int candidateCount;
  bool measuring = false;
  final List<Outcome> _held = [];

  SelectionDecision take(Outcome outcome, {required bool responded}) {
    if (candidateCount <= 1) {
      if (responded) {
        measuring = true;
      }
      return SelectionDecision(commit: [outcome]);
    }
    if (measuring) {
      return SelectionDecision(commit: [outcome]);
    }
    if (responded) {
      final skipped = _held.length;
      final next = skipped == 0
          ? outcome
          : _attach(outcome, _fallbackText(_held, outcome), skipped);
      _held.clear();
      measuring = true;
      return SelectionDecision(commit: [next], skipped: skipped);
    }
    _held.add(outcome);
    if (_held.length >= candidateCount) {
      final commit = List<Outcome>.of(_held);
      _held.clear();
      return SelectionDecision(commit: commit);
    }
    return const SelectionDecision(commit: []);
  }

  void endMeasurement() {
    measuring = false;
  }
}

Outcome _attach(Outcome outcome, String fallback, int skipped) {
  return Outcome(
    status: outcome.status,
    kind: outcome.kind,
    rttMs: outcome.rttMs,
    note: outcome.note,
    reconnect: outcome.reconnect,
    selectionSkipped: outcome.selectionSkipped + skipped,
    detail: {...outcome.detail, 'fallback': fallback},
  );
}

String _fallbackText(List<Outcome> held, Outcome success) {
  final failed = held
      .map((outcome) {
        final address = outcome.detail['address'];
        final family = outcome.detail['family'];
        final where = address == null || address.isEmpty
            ? '未知地址'
            : (family == null || family.isEmpty)
            ? address
            : '$address（$family）';
        final why = outcome.note.isEmpty ? '没有成功' : outcome.note;
        return '$where：$why';
      })
      .join('；');
  final used = success.detail['address'] ?? '';
  final usedFamily = success.detail['family'] ?? '';
  final usedText = used.isEmpty
      ? '另一个地址'
      : usedFamily.isEmpty
      ? used
      : '$used（$usedFamily）';
  return '候选未成功：$failed。已改用 $usedText。这些失败没有计入正式丢包或失败率。';
}

/// Stop discards the attempt that was still in flight. A finished attempt
/// whose note says it was stopped is not a measured loss either.
bool countsAfterStop(Outcome? outcome, {required bool cancelled}) {
  if (cancelled || outcome == null) {
    return false;
  }
  return outcome.note != '已停止';
}
