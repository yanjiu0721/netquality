// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import '../content/release_history.dart';
import 'update_check.dart';

/// SharedPreferences key for the last release list that a source actually returned.
const releaseHistoryCacheKey = 'netquality.release-history.v1';

enum HistoryOrigin { remote, cache, bundled }

class ReleaseCache {
  const ReleaseCache({required this.source, required this.entries});

  final String source;
  final List<ReleaseEntry> entries;
}

class ReleaseSync {
  const ReleaseSync({
    required this.entries,
    required this.note,
    required this.origin,
    this.cacheJson,
    this.used,
  });

  final List<ReleaseEntry> entries;
  final String note;
  final HistoryOrigin origin;

  /// Non-null when [origin] is [HistoryOrigin.remote] and the list should be saved.
  final String? cacheJson;
  final UpdateSource? used;
}

class ReleasePage {
  const ReleasePage({required this.entries, required this.complete});

  final List<ReleaseEntry> entries;

  /// False when this page was full and another page may exist.
  final bool complete;
}

/// Turns a `/releases/latest` URL into one page of the release list.
/// GitHub pages with `per_page`; Gitea pages with `limit`. A testing override
/// of the latest URL is reused, so the list follows `NQ_UPDATE_*_API`.
Uri releaseListUri(
  String latestUrl, {
  required UpdateSource source,
  required int page,
  required int pageSize,
}) {
  final parsed = Uri.parse(latestUrl.trim());
  var path = parsed.path;
  if (path.endsWith('/latest')) {
    path = path.substring(0, path.length - '/latest'.length);
  }
  final params = Map<String, String>.from(parsed.queryParameters);
  if (source == UpdateSource.github) {
    params['per_page'] = '$pageSize';
    params.remove('limit');
  } else {
    params['limit'] = '$pageSize';
    params.remove('per_page');
  }
  params['page'] = '$page';
  return parsed.replace(path: path, queryParameters: params);
}

/// GitHub and Gitea both return `tag_name`, `name`, `body`, `published_at`,
/// `draft`, `prerelease`, and `assets[].browser_download_url`. A list page is
/// a JSON array. A single release object is accepted so a `/latest` body can
/// still be shown. An error object is not a page.
ReleasePage? parseReleasePage(
  String body, {
  required String sourceLabel,
  required int pageSize,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is Map) {
    if (decoded['tag_name'] is! String) {
      return null;
    }
    final entry = _entryFromRelease(
      Map<String, dynamic>.from(decoded),
      sourceLabel: sourceLabel,
    );
    return ReleasePage(entries: [?entry], complete: true);
  }
  if (decoded is! List) {
    return null;
  }
  final entries = <ReleaseEntry>[];
  for (final item in decoded) {
    if (item is! Map) {
      continue;
    }
    final entry = _entryFromRelease(
      Map<String, dynamic>.from(item),
      sourceLabel: sourceLabel,
    );
    if (entry != null) {
      entries.add(entry);
    }
  }
  return ReleasePage(entries: entries, complete: decoded.length < pageSize);
}

ReleaseEntry? _entryFromRelease(
  Map<String, dynamic> json, {
  required String sourceLabel,
}) {
  if (json['draft'] == true) {
    return null;
  }
  final tag = json['tag_name'];
  if (tag is! String) {
    return null;
  }
  final version = SemVer.parse(tag);
  if (version == null) {
    return null;
  }
  final versionText = '${version.major}.${version.minor}.${version.patch}';
  final name = json['name'];
  final title = name is String && name.trim().isNotEmpty
      ? name.trim()
      : '网络质量探测 $versionText';
  final body = json['body'] is String ? json['body'] as String : '';
  final points = notesToPoints(body, title: title);
  if (points.isEmpty) {
    points.add('这次发布没有正文。');
  }
  final pre = json['prerelease'] == true;
  final published = _publishedDay(json['published_at']);
  final tagText = tag.trim();
  return ReleaseEntry(
    version: versionText,
    tag: tagText,
    title: title,
    published: published,
    source: '来自 $sourceLabel · 标签 $tagText${pre ? ' · 预发布' : ''}',
    points: points,
  );
}

String? _publishedDay(Object? raw) {
  if (raw is! String || raw.length < 10) {
    return null;
  }
  final day = raw.substring(0, 10);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
    return null;
  }
  return day;
}

/// Splits a release body into the short points the history page already shows.
/// Headings and bullet items each become one point. A title repeated as the
/// first heading is dropped. Versions that are not in the body are not added.
List<String> notesToPoints(String body, {String title = ''}) {
  final points = <String>[];
  final buffer = StringBuffer();
  void flush() {
    final text = _plain(buffer.toString());
    buffer.clear();
    if (text.isNotEmpty) {
      points.add(text);
    }
  }

  for (final raw in body.replaceAll('\r\n', '\n').split('\n')) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      flush();
      continue;
    }
    if (trimmed.startsWith('```')) {
      flush();
      continue;
    }
    final heading = RegExp(r'^#{1,6}\s+').firstMatch(trimmed);
    if (heading != null) {
      flush();
      final text = _plain(trimmed.substring(heading.end));
      if (text.isNotEmpty) {
        points.add(text);
      }
      continue;
    }
    final bullet = RegExp(r'^[-*+]\s+').firstMatch(trimmed);
    if (bullet != null) {
      flush();
      final text = _plain(trimmed.substring(bullet.end));
      if (text.isNotEmpty) {
        points.add(text);
      }
      continue;
    }
    if (buffer.isNotEmpty) {
      buffer.write(' ');
    }
    buffer.write(trimmed);
  }
  flush();
  if (points.isNotEmpty && title.isNotEmpty && points.first == title) {
    points.removeAt(0);
  }
  return points;
}

String _plain(String input) {
  var text = input.trim();
  text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (match) {
    final label = match.group(1)!.trim();
    final url = match.group(2)!.trim();
    if (label.isEmpty) {
      return url;
    }
    if (url.isEmpty || url == label) {
      return label;
    }
    return '$label（$url）';
  });
  text = text.replaceAll('`', '');
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  return text.trim();
}

String encodeReleaseCache({
  required String source,
  required List<ReleaseEntry> entries,
}) {
  return jsonEncode({
    'source': source,
    'entries': [for (final entry in entries) entry.toJson()],
  });
}

ReleaseCache? decodeReleaseCache(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final source = decoded['source'];
    final rawEntries = decoded['entries'];
    if (source is! String || rawEntries is! List) {
      return null;
    }
    final entries = <ReleaseEntry>[];
    for (final item in rawEntries) {
      if (item is! Map) {
        continue;
      }
      final entry = ReleaseEntry.fromJson(Map<String, dynamic>.from(item));
      if (entry.version.isEmpty && entry.title.isEmpty) {
        continue;
      }
      entries.add(entry);
    }
    return ReleaseCache(source: source, entries: entries);
  } on FormatException {
    return null;
  }
}

String freshHistoryNote({
  required String sourceLabel,
  required bool fellBack,
  required bool preferredRateLimited,
  required bool incomplete,
  required bool empty,
}) {
  final head = !fellBack
      ? '已从 $sourceLabel 同步。'
      : preferredRateLimited
      ? '所选更新源暂时限制了请求次数，这次改用了 $sourceLabel。'
      : '所选更新源连不上，这次改用了 $sourceLabel。';
  final tail = empty
      ? '这个更新源目前没有已发布的版本。'
      : incomplete
      ? '后面的页没有取完，可能不是全部。'
      : '比当前安装更新的发布也会列在这里。';
  return '$head$tail';
}

String staleHistoryNote({
  required bool rateLimited,
  required bool hasCache,
  String? sourceLabel,
}) {
  final reason = rateLimited ? '更新源暂时限制了请求次数' : '网络暂时连不上';
  if (!hasCache) {
    return '$reason，也没有保存过在线列表。下面是安装包里的说明，可能不是最新。';
  }
  final from = sourceLabel == null || sourceLabel.isEmpty
      ? ''
      : '从 $sourceLabel ';
  return '$reason。下面是上次$from保存的列表，可能不是最新。';
}

String? cacheSourceLabel(String source) {
  if (source == updateSourceGithub) {
    return updateSourceLabel(UpdateSource.github);
  }
  if (source == updateSourceGitea) {
    return updateSourceLabel(UpdateSource.gitea);
  }
  return null;
}

/// Reads the chosen source's release list, then the other source if that
/// fails. A network failure keeps [cachedJson], or [bundled] when nothing
/// has been saved. Published releases newer than the installed app stay in
/// the list; versions that the payload does not contain are not added.
Future<ReleaseSync> syncReleaseHistory({
  required UpdateSource preferred,
  required UpdateEndpoints endpoints,
  required Future<String?> Function(Uri url) fetch,
  String? cachedJson,
  List<ReleaseEntry> bundled = releaseHistory,
  int pageLimit = 5,
  int githubPageSize = 100,
  int giteaPageSize = 50,
}) async {
  final order = preferred == UpdateSource.github
      ? const [UpdateSource.github, UpdateSource.gitea]
      : const [UpdateSource.gitea, UpdateSource.github];
  var sawRate = false;
  var preferredRate = false;
  for (var i = 0; i < order.length; i++) {
    final source = order[i];
    final pageSize = source == UpdateSource.github
        ? githubPageSize
        : giteaPageSize;
    try {
      final read = await _readSource(
        latestUrl: endpoints.latestFor(source),
        source: source,
        fetch: fetch,
        pageLimit: pageLimit,
        pageSize: pageSize,
      );
      if (read == null) {
        continue;
      }
      final entries = _sortedUnique(read.entries);
      return ReleaseSync(
        entries: entries,
        origin: HistoryOrigin.remote,
        used: source,
        cacheJson: encodeReleaseCache(
          source: updateSourceId(source),
          entries: entries,
        ),
        note: freshHistoryNote(
          sourceLabel: updateSourceLabel(source),
          fellBack: i > 0,
          preferredRateLimited: i > 0 && preferredRate,
          incomplete: read.incomplete,
          empty: entries.isEmpty,
        ),
      );
    } on UpdateFetchException catch (error) {
      if (error.rateLimited) {
        sawRate = true;
        if (i == 0) {
          preferredRate = true;
        }
      }
    }
  }
  return _offline(
    cachedJson: cachedJson,
    bundled: bundled,
    rateLimited: sawRate,
  );
}

class _SourceRead {
  const _SourceRead({required this.entries, required this.incomplete});

  final List<ReleaseEntry> entries;
  final bool incomplete;
}

Future<_SourceRead?> _readSource({
  required String latestUrl,
  required UpdateSource source,
  required Future<String?> Function(Uri url) fetch,
  required int pageLimit,
  required int pageSize,
}) async {
  final entries = <ReleaseEntry>[];
  final label = updateSourceLabel(source);
  for (var page = 1; page <= pageLimit; page++) {
    final uri = releaseListUri(
      latestUrl,
      source: source,
      page: page,
      pageSize: pageSize,
    );
    String? body;
    try {
      body = await fetch(uri);
    } on UpdateFetchException {
      if (page == 1) {
        rethrow;
      }
      return _SourceRead(entries: entries, incomplete: true);
    } on Object {
      if (page == 1) {
        return null;
      }
      return _SourceRead(entries: entries, incomplete: true);
    }
    if (body == null) {
      if (page == 1) {
        return null;
      }
      return _SourceRead(entries: entries, incomplete: true);
    }
    final parsed = parseReleasePage(
      body,
      sourceLabel: label,
      pageSize: pageSize,
    );
    if (parsed == null) {
      if (page == 1) {
        return null;
      }
      return _SourceRead(entries: entries, incomplete: true);
    }
    entries.addAll(parsed.entries);
    if (parsed.complete) {
      return _SourceRead(entries: entries, incomplete: false);
    }
    if (page == pageLimit) {
      return _SourceRead(entries: entries, incomplete: true);
    }
  }
  return _SourceRead(entries: entries, incomplete: true);
}

List<ReleaseEntry> _sortedUnique(List<ReleaseEntry> entries) {
  final sorted = [...entries];
  sorted.sort((a, b) {
    final av = SemVer.parse(a.version);
    final bv = SemVer.parse(b.version);
    if (av != null && bv != null) {
      final compared = bv.compareTo(av);
      if (compared != 0) {
        return compared;
      }
    }
    final published = (b.published ?? '').compareTo(a.published ?? '');
    if (published != 0) {
      return published;
    }
    return (a.tag ?? '').compareTo(b.tag ?? '');
  });
  final seen = <String>{};
  final unique = <ReleaseEntry>[];
  for (final entry in sorted) {
    final key = (entry.tag == null || entry.tag!.isEmpty)
        ? entry.version
        : entry.tag!;
    if (key.isEmpty || !seen.add(key)) {
      continue;
    }
    unique.add(entry);
  }
  return unique;
}

ReleaseSync _offline({
  required String? cachedJson,
  required List<ReleaseEntry> bundled,
  required bool rateLimited,
}) {
  final cache = decodeReleaseCache(cachedJson);
  if (cache != null) {
    return ReleaseSync(
      entries: cache.entries,
      origin: HistoryOrigin.cache,
      note: staleHistoryNote(
        rateLimited: rateLimited,
        hasCache: true,
        sourceLabel: cacheSourceLabel(cache.source),
      ),
    );
  }
  return ReleaseSync(
    entries: bundled,
    origin: HistoryOrigin.bundled,
    note: staleHistoryNote(rateLimited: rateLimited, hasCache: false),
  );
}

/// Same sync as [syncReleaseHistory], plus reading and writing the local cache.
/// [allowNetwork] is false in widget tests so opening history does not call out.
Future<ReleaseSync> syncAndStore({
  required UpdateSource preferred,
  required UpdateEndpoints endpoints,
  required Future<String?> Function(Uri url) fetch,
  required Future<String?> Function() readCache,
  required Future<void> Function(String json) writeCache,
  bool allowNetwork = true,
  List<ReleaseEntry> bundled = releaseHistory,
  int pageLimit = 5,
  int githubPageSize = 100,
  int giteaPageSize = 50,
}) async {
  final cached = await readCache();
  if (!allowNetwork) {
    final stored = decodeReleaseCache(cached);
    if (stored != null) {
      return ReleaseSync(
        entries: stored.entries,
        origin: HistoryOrigin.cache,
        note: '下面是上次保存的列表。',
      );
    }
    return ReleaseSync(
      entries: bundled,
      origin: HistoryOrigin.bundled,
      note: '',
    );
  }
  final result = await syncReleaseHistory(
    preferred: preferred,
    endpoints: endpoints,
    fetch: fetch,
    cachedJson: cached,
    bundled: bundled,
    pageLimit: pageLimit,
    githubPageSize: githubPageSize,
    giteaPageSize: giteaPageSize,
  );
  final json = result.cacheJson;
  if (json != null) {
    await writeCache(json);
  }
  return result;
}
