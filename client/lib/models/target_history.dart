// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

/// A recent probe target. This list is local and never stores node tokens,
/// center credentials, cookies, or request bodies.
class TargetEntry {
  const TargetEntry({
    required this.host,
    required this.port,
    required this.profileId,
    this.httpUrl = '',
    this.method = '',
    required this.savedAtMs,
  });

  final String host;
  final int port;
  final String profileId;
  final String httpUrl;
  final String method;
  final int savedAtMs;

  String get key {
    final http = profileId == 'http';
    return [
      profileId,
      '$port',
      host.trim(),
      http ? httpUrl.trim() : '',
      http ? method.trim().toUpperCase() : '',
    ].join('\u0001');
  }

  String get label {
    if (profileId == 'http') {
      final where = httpUrl.trim().isNotEmpty ? httpUrl.trim() : host.trim();
      final methodText = method.trim().isNotEmpty
          ? ' ${method.trim().toUpperCase()}'
          : '';
      return '$where · HTTP$methodText';
    }
    return '${host.trim()}:$port · $profileId';
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'profileId': profileId,
    'httpUrl': httpUrl,
    'method': method,
    'savedAtMs': savedAtMs,
  };

  factory TargetEntry.fromJson(Map<String, dynamic> json) {
    return TargetEntry(
      host: json['host'] is String ? json['host'] as String : '',
      port: json['port'] is int ? json['port'] as int : 0,
      profileId: json['profileId'] is String ? json['profileId'] as String : '',
      httpUrl: json['httpUrl'] is String ? json['httpUrl'] as String : '',
      method: json['method'] is String ? json['method'] as String : '',
      savedAtMs: json['savedAtMs'] is int ? json['savedAtMs'] as int : 0,
    );
  }
}

class TargetHistory {
  const TargetHistory(this.entries);

  static const maxEntries = 40;
  static const empty = TargetHistory([]);

  final List<TargetEntry> entries;

  TargetHistory add(TargetEntry entry) {
    final next = [
      entry,
      for (final item in entries)
        if (item.key != entry.key) item,
    ];
    if (next.length > maxEntries) {
      return TargetHistory(next.sublist(0, maxEntries));
    }
    return TargetHistory(next);
  }

  TargetHistory removeAt(int index) {
    if (index < 0 || index >= entries.length) {
      return this;
    }
    return TargetHistory([
      for (var i = 0; i < entries.length; i++)
        if (i != index) entries[i],
    ]);
  }

  TargetHistory clear() => empty;

  String encode() =>
      jsonEncode(entries.map((entry) => entry.toJson()).toList());

  factory TargetHistory.decode(String raw) {
    if (raw.trim().isEmpty) {
      return empty;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return empty;
    }
    return TargetHistory([
      for (final item in decoded)
        if (item is Map) TargetEntry.fromJson(Map<String, dynamic>.from(item)),
    ]);
  }
}
