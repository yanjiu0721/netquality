// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

/// Latency over successful round-trips only.
///
/// * current: the latest successful sample, stored separately as `rttMs`
/// * min / max: smallest and largest successful sample
/// * mean: arithmetic mean
/// * median: the middle sample after sorting; when the count is even, the
///   mean of the two middle samples
/// * p95: nearest-rank. Rank is `ceil(0.95 * n)` computed as
///   `(95 * n + 99) ~/ 100` so binary floating point cannot move the rank.
///   Rank is 1-based and then clamped to the sample count.
class LatencyStats {
  const LatencyStats({
    required this.min,
    required this.mean,
    required this.median,
    required this.p95,
    required this.max,
  });

  final double min;
  final double mean;
  final double median;
  final double p95;
  final double max;

  static LatencyStats? from(List<double> samples) {
    if (samples.isEmpty) {
      return null;
    }
    final sorted = [...samples]..sort();
    var sum = 0.0;
    for (final value in sorted) {
      sum += value;
    }
    final count = sorted.length;
    final median = count.isOdd
        ? sorted[count ~/ 2]
        : (sorted[count ~/ 2 - 1] + sorted[count ~/ 2]) / 2;
    final rank = nearestRank95(count);
    return LatencyStats(
      min: sorted.first,
      mean: sum / count,
      median: median,
      p95: sorted[rank - 1],
      max: sorted.last,
    );
  }
}

int nearestRank95(int count) {
  if (count <= 1) {
    return 1;
  }
  final rank = (95 * count + 99) ~/ 100;
  if (rank < 1) {
    return 1;
  }
  if (rank > count) {
    return count;
  }
  return rank;
}
