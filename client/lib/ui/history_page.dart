// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../content/release_history.dart';
import '../version.dart';
import 'quality_charts.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Scaffold(
      appBar: AppBar(
        title: const Text('更新历史'),
        backgroundColor: const Color(0xFFF3F1EC),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                wide ? 24 : 12,
                8,
                wide ? 24 : 12,
                28,
              ),
              children: [
                Text(
                  '当前版本 $appVersion（构建 $appBuild） · 署名 $appAttribution · $appLicense',
                  style: const TextStyle(
                    color: ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  releaseHistoryNote,
                  style: TextStyle(color: muted, height: 1.4),
                ),
                const SizedBox(height: 12),
                for (final entry in releaseHistory) _entry(entry),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(ReleaseEntry entry) {
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
              entry.title,
              style: const TextStyle(fontWeight: FontWeight.w700, color: ink),
            ),
            const SizedBox(height: 6),
            Text(
              entry.published == null
                  ? entry.source
                  : '${entry.published} · ${entry.source}',
              style: const TextStyle(color: muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 8),
            for (final point in entry.points)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('· $point', style: const TextStyle(height: 1.4)),
              ),
          ],
        ),
      ),
    );
  }
}
