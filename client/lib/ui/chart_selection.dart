// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

const chartPinEpsilon = 0.0001;

class ChartSelection {
  const ChartSelection({required this.sec, required this.sessionId});

  final double sec;
  final int sessionId;
}

/// A tap chooses the nearest sample and keeps it after the pointer is
/// released. A new session, an empty series, or a point that has scrolled
/// off the front of the window clears the pin instead of jumping to another
/// sample. [tappedSec] null means "keep the current pin if it is still valid".
ChartSelection? nextChartSelection({
  required ChartSelection? current,
  required int sessionId,
  required List<double> sampleSecs,
  double? tappedSec,
}) {
  if (tappedSec != null) {
    double? nearest;
    var best = double.infinity;
    for (final sec in sampleSecs) {
      final distance = (sec - tappedSec).abs();
      if (distance < best) {
        best = distance;
        nearest = sec;
      }
    }
    if (nearest == null) {
      return null;
    }
    return ChartSelection(sec: nearest, sessionId: sessionId);
  }
  if (current == null || current.sessionId != sessionId || sampleSecs.isEmpty) {
    return null;
  }
  if (current.sec + chartPinEpsilon < sampleSecs.first) {
    return null;
  }
  for (final sec in sampleSecs) {
    if ((sec - current.sec).abs() <= chartPinEpsilon) {
      return current;
    }
  }
  return null;
}
