import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../probe/probe_controller.dart';
import 'chart_selection.dart';
import 'format.dart';

const rttColor = Color(0xFF1F4E79);
const rateColor = Color(0xFF9A3412);
const ink = Color(0xFF1C2430);
const muted = Color(0xFF5E6872);
const line = Color(0xFFE4DFD4);

class QualityCharts extends StatefulWidget {
  const QualityCharts({
    super.key,
    required this.samples,
    required this.rateLabel,
    required this.running,
    required this.sessionId,
  });

  final List<ChartSample> samples;
  final String rateLabel;
  final bool running;
  final int sessionId;

  @override
  State<QualityCharts> createState() => _QualityChartsState();
}

class _QualityChartsState extends State<QualityCharts> {
  ChartSelection? _pin;

  @override
  void didUpdateWidget(QualityCharts oldWidget) {
    super.didUpdateWidget(oldWidget);
    final kept = nextChartSelection(
      current: _pin,
      sessionId: widget.sessionId,
      sampleSecs: [for (final sample in widget.samples) sample.sec],
    );
    if (kept?.sec != _pin?.sec || kept?.sessionId != _pin?.sessionId) {
      _pin = kept;
    }
  }

  void _pinAt(double sec) {
    setState(() {
      _pin = nextChartSelection(
        current: _pin,
        sessionId: widget.sessionId,
        sampleSecs: [for (final sample in widget.samples) sample.sec],
        tappedSec: sec,
      );
    });
  }

  ChartSample? get _pinnedSample {
    final pin = _pin;
    if (pin == null || pin.sessionId != widget.sessionId) {
      return null;
    }
    for (final sample in widget.samples) {
      if ((sample.sec - pin.sec).abs() <= chartPinEpsilon) {
        return sample;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pinned = _pinnedSample;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            _Swatch(color: rttColor, label: '往返时间'),
            SizedBox(width: 16),
            _Swatch(color: rateColor, label: '比率'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          pinned == null
              ? '点曲线上的一点可以钉住该时刻，松手后仍会保留。再点另一点会更换。'
              : pinnedReadout(pinned, widget.rateLabel),
          key: const Key('chart-pin'),
          style: const TextStyle(color: ink, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 8),
        _ChartCard(
          title: '延迟',
          unit: 'ms',
          samples: widget.samples,
          read: (sample) => sample.rttMs,
          color: rttColor,
          floor: 1,
          running: widget.running,
          pinnedSec: pinned?.sec,
          onPin: _pinAt,
        ),
        _ChartCard(
          title: widget.rateLabel,
          unit: '%',
          samples: widget.samples,
          read: (sample) => sample.ratePct,
          color: rateColor,
          floor: 10,
          running: widget.running,
          pinnedSec: pinned?.sec,
          onPin: _pinAt,
        ),
      ],
    );
  }
}

String pinnedReadout(ChartSample sample, String rateLabel) {
  final latency = sample.rttMs == null
      ? '这一刻没有延迟'
      : '延迟 ${formatMs(sample.rttMs)}';
  final rate = sample.ratePct == null
      ? '$rateLabel —'
      : '$rateLabel ${formatPct(sample.ratePct)}';
  return '已选 ${sample.sec.toStringAsFixed(1)} 秒 · $latency · $rate';
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: muted, fontSize: 12)),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.unit,
    required this.samples,
    required this.read,
    required this.color,
    required this.floor,
    required this.running,
    required this.pinnedSec,
    required this.onPin,
  });

  final String title;
  final String unit;
  final List<ChartSample> samples;
  final double? Function(ChartSample sample) read;
  final Color color;
  final double floor;
  final bool running;
  final double? pinnedSec;
  final void Function(double sec) onPin;

  @override
  Widget build(BuildContext context) {
    final spots = _spots();
    final hasData = spots.any((spot) => !spot.isNull());
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: line),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title（$unit）',
              style: const TextStyle(
                color: ink,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 168,
              child: hasData
                  ? _lineChart(spots)
                  : Center(
                      child: Text(
                        running ? '正在等待第一次完成的探测。未完成的不会画成 100%。' : '暂无已完成的探测',
                        style: const TextStyle(color: muted),
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<FlSpot> _spots() {
    final spots = <FlSpot>[];
    for (final sample in samples) {
      final value = read(sample);
      if (value == null) {
        if (spots.isNotEmpty && !spots.last.isNull()) {
          spots.add(FlSpot.nullSpot);
        }
      } else {
        spots.add(FlSpot(sample.sec, value));
      }
    }
    if (spots.isNotEmpty && spots.last.isNull()) {
      spots.removeLast();
    }
    return spots;
  }

  Widget _lineChart(List<FlSpot> spots) {
    final minX = samples.first.sec;
    var maxX = samples.last.sec;
    if (maxX - minX < 1) {
      maxX = minX + 1;
    }
    var maxY = floor;
    for (final spot in spots) {
      if (!spot.isNull() && spot.y > maxY) {
        maxY = spot.y;
      }
    }
    maxY = maxY * 1.2;
    final yInterval = _yInterval(maxY);
    final xInterval = _xInterval(maxX - minX);
    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: line, strokeWidth: 1),
        ),
        borderData: FlBorderData(
          show: true,
          border: const Border(
            left: BorderSide(color: line),
            bottom: BorderSide(color: line),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: yInterval,
              getTitlesWidget: (value, meta) =>
                  _axisLabel(_formatTick(value, maxY)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: xInterval,
              getTitlesWidget: (value, meta) =>
                  _axisLabel('${value.toStringAsFixed(0)}s'),
            ),
          ),
        ),
        extraLinesData: ExtraLinesData(
          verticalLines: [
            if (pinnedSec != null)
              VerticalLine(
                x: pinnedSec!,
                color: color.withValues(alpha: 0.85),
                strokeWidth: 1.5,
              ),
          ],
        ),
        lineTouchData: LineTouchData(
          handleBuiltInTouches: false,
          touchSpotThreshold: 18,
          touchCallback: (event, response) {
            if (event is! FlTapUpEvent) {
              return;
            }
            final spots = response?.lineBarSpots;
            if (spots == null || spots.isEmpty) {
              return;
            }
            onPin(spots.first.x);
          },
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: color,
            barWidth: 2,
            dotData: FlDotData(
              show: pinnedSec != null,
              checkToShowDot: (spot, _) =>
                  pinnedSec != null &&
                  (spot.x - pinnedSec!).abs() <= chartPinEpsilon,
            ),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.10),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

Widget _axisLabel(String text) {
  return Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Text(text, style: const TextStyle(color: muted, fontSize: 10)),
  );
}

double _yInterval(double maxY) {
  if (maxY <= 1) {
    return 0.25;
  }
  if (maxY <= 5) {
    return 1;
  }
  if (maxY <= 20) {
    return 5;
  }
  if (maxY <= 50) {
    return 10;
  }
  if (maxY <= 120) {
    return 20;
  }
  if (maxY <= 300) {
    return 50;
  }
  return 100;
}

double _xInterval(double span) {
  if (span <= 15) {
    return 5;
  }
  if (span <= 40) {
    return 10;
  }
  return 15;
}

String _formatTick(double value, double maxY) {
  if (maxY < 5) {
    return value.toStringAsFixed(value < 1 ? 2 : 1);
  }
  return value.toStringAsFixed(0);
}
