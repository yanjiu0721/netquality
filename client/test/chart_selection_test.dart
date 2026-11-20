// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

// The plot surface is not part of fl_chart's public API. The tap has to land
// on that surface, not on the axis titles around it.
// ignore_for_file: implementation_imports

import 'package:fl_chart/src/chart/line_chart/line_chart_renderer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/probe/probe_controller.dart';
import 'package:netquality/ui/chart_selection.dart';
import 'package:netquality/ui/quality_charts.dart';

void main() {
  test('a tap pins the nearest time and a later tap replaces it', () {
    final first = nextChartSelection(
      current: null,
      sessionId: 3,
      sampleSecs: const [1, 2, 4],
      tappedSec: 2.2,
    );
    expect(first, isNotNull);
    expect(first!.sec, 2);
    expect(first.sessionId, 3);

    final second = nextChartSelection(
      current: first,
      sessionId: 3,
      sampleSecs: const [1, 2, 4],
      tappedSec: 3.6,
    );
    expect(second!.sec, 4);

    final kept = nextChartSelection(
      current: second,
      sessionId: 3,
      sampleSecs: const [1, 2, 4],
    );
    expect(kept, same(second));
  });

  test('a new session or a point that rolled off does not jump', () {
    const pin = ChartSelection(sec: 1, sessionId: 3);
    expect(
      nextChartSelection(current: pin, sessionId: 4, sampleSecs: const [1, 2]),
      isNull,
    );
    expect(
      nextChartSelection(current: pin, sessionId: 3, sampleSecs: const [2, 3]),
      isNull,
    );
    expect(
      nextChartSelection(current: pin, sessionId: 3, sampleSecs: const []),
      isNull,
    );
  });

  testWidgets('releasing a chart tap keeps the pinned readout', (tester) async {
    const samples = [
      ChartSample(sec: 0, rttMs: 10, ratePct: 0),
      ChartSample(sec: 1, rttMs: 30, ratePct: 50),
    ];
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: QualityCharts(
            samples: samples,
            rateLabel: '探测无应答',
            running: false,
            sessionId: 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('点曲线上的一点'), findsOneWidget);

    final box = tester.getRect(find.byType(LineChartLeaf).first);
    const maxY = 30 * 1.2;
    Offset at(double sec, double value) {
      final x = box.left + box.width * sec;
      final y = box.top + (1 - value / maxY) * box.height;
      return Offset(x.clamp(box.left + 2, box.right - 2), y);
    }

    await tester.tapAt(at(0, 10));
    await tester.pump();
    expect(find.textContaining('已选 0.0 秒'), findsOneWidget);
    expect(find.textContaining('延迟'), findsWidgets);

    final mouse = await tester.startGesture(
      at(1, 30),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pump();
    expect(find.textContaining('已选 1.0 秒'), findsOneWidget);
    expect(find.textContaining('已选 0.0 秒'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: QualityCharts(
            samples: [ChartSample(sec: 2, rttMs: 8, ratePct: 0)],
            rateLabel: '探测无应答',
            running: false,
            sessionId: 1,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing);
    expect(find.textContaining('点曲线上的一点'), findsOneWidget);
  });
}
