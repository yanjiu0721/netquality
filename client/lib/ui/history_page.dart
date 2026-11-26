// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../content/release_history.dart';
import '../update/apply_update.dart';
import '../update/release_feed.dart';
import '../update/update_check.dart';
import '../version.dart';
import 'quality_charts.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.updateSource = UpdateSource.gitea});

  final UpdateSource updateSource;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  var _entries = const <ReleaseEntry>[];
  var _note = '正在读取发布说明…';
  var _showBundledNote = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = await readStoredReleaseHistory();
    if (!mounted) {
      return;
    }
    if (cached != null) {
      setState(() {
        _entries = cached.entries;
        _note = '正在向${updateSourceLabel(widget.updateSource)}核对发布说明…';
        _showBundledNote = false;
      });
    }
    try {
      final result = await loadReleaseHistory(widget.updateSource);
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = result.entries;
        _note = result.note;
        _showBundledNote = result.origin == HistoryOrigin.bundled;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = releaseHistory;
        _note = staleHistoryNote(rateLimited: false, hasCache: false);
        _showBundledNote = true;
      });
    }
  }

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
                if (_note.isNotEmpty)
                  Text(
                    _note,
                    style: const TextStyle(color: muted, height: 1.4),
                  ),
                const SizedBox(height: 8),
                const Text(
                  onlineHistoryLimitNote,
                  style: TextStyle(color: muted, height: 1.4),
                ),
                if (_showBundledNote) ...[
                  const SizedBox(height: 8),
                  const Text(
                    releaseHistoryNote,
                    style: TextStyle(color: muted, height: 1.4),
                  ),
                ],
                const SizedBox(height: 12),
                for (final entry in _entries) _entry(entry),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(ReleaseEntry entry) {
    final remote = SemVer.parse(entry.version);
    final local = SemVer.parse(appVersion);
    final newer = remote != null && local != null && remote.isNewerThan(local);
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
            if (newer) ...[
              const SizedBox(height: 6),
              Text(
                '比当前安装的 $appVersion 新',
                style: const TextStyle(color: Color(0xFF9A3412), fontSize: 13),
              ),
            ],
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
