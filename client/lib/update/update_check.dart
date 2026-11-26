// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

/// Where release metadata is downloaded from. YanJiu Git is the default
/// because github.com is often blocked by DNS pollution on the user's network.
enum UpdateSource { gitea, github }

const updateSourceGitea = 'gitea';
const updateSourceGithub = 'github';

UpdateSource parseUpdateSource(String? raw) =>
    raw == updateSourceGithub ? UpdateSource.github : UpdateSource.gitea;

String updateSourceId(UpdateSource source) =>
    source == UpdateSource.github ? updateSourceGithub : updateSourceGitea;

String updateSourceLabel(UpdateSource source) =>
    source == UpdateSource.github ? 'GitHub' : 'YanJiu Git';

/// Environment variables override the live release URLs. Empty values keep
/// the defaults, so a blank test variable does not point the client nowhere.
UpdateEndpoints updateEndpoints({String? githubApi, String? giteaApi}) {
  return UpdateEndpoints(
    github: githubApi == null || githubApi.trim().isEmpty
        ? UpdateEndpoints.githubDefault
        : githubApi.trim(),
    gitea: giteaApi == null || giteaApi.trim().isEmpty
        ? UpdateEndpoints.giteaDefault
        : giteaApi.trim(),
  );
}

/// 429, a spent quota header, or a 403 body that says the limit was hit.
bool isReleaseRateLimited({
  required int status,
  String? rateLimitRemaining,
  required String body,
}) {
  if (status == 429) {
    return true;
  }
  if (status != 403) {
    return false;
  }
  if (rateLimitRemaining == '0') {
    return true;
  }
  return body.toLowerCase().contains('rate limit');
}

/// The release API refused the request because the caller asked too often.
class UpdateFetchException implements Exception {
  const UpdateFetchException({required this.rateLimited, this.status});

  final bool rateLimited;
  final int? status;

  @override
  String toString() =>
      'UpdateFetchException(rateLimited: $rateLimited, status: $status)';
}

/// Numeric version. A leading v and a +build suffix are ignored.
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static SemVer? parse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    final plus = text.indexOf('+');
    if (plus >= 0) {
      text = text.substring(0, plus);
    }
    final dash = text.indexOf('-');
    if (dash >= 0) {
      text = text.substring(0, dash);
    }
    final parts = text.split('.');
    if (parts.length < 3) {
      return null;
    }
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = int.tryParse(parts[2]);
    if (major == null || minor == null || patch == null) {
      return null;
    }
    return SemVer(major, minor, patch);
  }

  bool isNewerThan(SemVer other) => compareTo(other) > 0;

  @override
  int compareTo(SemVer other) {
    if (major != other.major) {
      return major.compareTo(other.major);
    }
    if (minor != other.minor) {
      return minor.compareTo(other.minor);
    }
    return patch.compareTo(other.patch);
  }
}

class ReleaseFile {
  const ReleaseFile({required this.name, required this.url});

  final String name;
  final String url;
}

class UpdateEndpoints {
  const UpdateEndpoints({required this.github, required this.gitea});

  static const githubDefault =
      'https://api.github.com/repos/yanjiu0721/netquality/releases/latest';
  static const giteaDefault =
      'https://git.yanjiu.ltd/api/v1/repos/YanJiu/netquality/releases/latest';

  final String github;
  final String gitea;

  String latestFor(UpdateSource source) =>
      source == UpdateSource.github ? github : gitea;
}

class UpdateOffer {
  const UpdateOffer({
    required this.version,
    required this.assetName,
    required this.assetUrl,
    this.checksumName,
    this.checksumUrl,
  });

  final String version;
  final String assetName;
  final String assetUrl;
  final String? checksumName;
  final String? checksumUrl;
}

class UpdateCheck {
  const UpdateCheck({
    this.offer,
    required this.reachable,
    this.message = '',
    this.used,
    this.fellBack = false,
  });

  final UpdateOffer? offer;
  final bool reachable;
  final String message;

  /// The source that actually answered. Null when neither source could be used.
  final UpdateSource? used;

  /// True when [used] is the spare source because the chosen one failed.
  final bool fellBack;
}

/// Picks the client archive for this OS and CPU. Server packages are ignored.
String? pickClientAsset(
  List<ReleaseFile> assets, {
  required String os,
  required String arch,
}) {
  final wantOs = os.toLowerCase();
  final wantArch = arch.toLowerCase();
  for (final asset in assets) {
    final name = asset.name.toLowerCase();
    if (name.contains('server') || name.contains('reflector')) {
      continue;
    }
    if (wantOs == 'android') {
      if (name.endsWith('.apk') && name.contains(wantArch)) {
        return asset.name;
      }
      continue;
    }
    final archOk =
        name.contains(wantArch) ||
        (wantArch == 'amd64' && name.contains('x86_64')) ||
        (wantArch == 'arm64' && name.contains('aarch64'));
    if (!archOk || !name.contains(wantOs)) {
      continue;
    }
    if (wantOs == 'windows' &&
        (name.endsWith('.zip') || name.endsWith('.exe'))) {
      return asset.name;
    }
    if (wantOs == 'linux' &&
        (name.endsWith('.tar.gz') || name.endsWith('.tgz'))) {
      return asset.name;
    }
  }
  return null;
}

bool looksLikeChecksum(String name) {
  final lower = name.toLowerCase();
  return lower.contains('sha256') || lower.contains('checksum');
}

UpdateCheck interpretRelease({
  required String current,
  required String? body,
  required String os,
  required String arch,
}) {
  if (body == null || body.trim().isEmpty) {
    return const UpdateCheck(reachable: false, message: '检查更新失败');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const UpdateCheck(reachable: false, message: '检查更新失败');
  }
  if (decoded is! Map) {
    return const UpdateCheck(reachable: false, message: '检查更新失败');
  }
  final tag = decoded['tag_name'];
  final remote = tag is String ? SemVer.parse(tag) : null;
  final local = SemVer.parse(current);
  if (remote == null || local == null) {
    return const UpdateCheck(reachable: true, message: '发布说明里的版本号无法比较');
  }
  if (!remote.isNewerThan(local)) {
    return UpdateCheck(reachable: true, message: '当前已经是 $current');
  }
  final assets = <ReleaseFile>[];
  final rawAssets = decoded['assets'];
  if (rawAssets is List) {
    for (final item in rawAssets) {
      if (item is! Map) {
        continue;
      }
      final name = item['name'];
      final url = item['browser_download_url'];
      final link = url is String ? url : '';
      if (name is String && link.isNotEmpty) {
        assets.add(ReleaseFile(name: name, url: link));
      }
    }
  }
  final pickedName = pickClientAsset(assets, os: os, arch: arch);
  if (pickedName == null) {
    return UpdateCheck(
      reachable: true,
      message:
          '发现 ${remote.major}.${remote.minor}.${remote.patch}，但没有适合这台设备的安装包',
    );
  }
  final picked = assets.firstWhere((asset) => asset.name == pickedName);
  ReleaseFile? sums;
  for (final asset in assets) {
    if (looksLikeChecksum(asset.name)) {
      sums = asset;
      break;
    }
  }
  return UpdateCheck(
    reachable: true,
    offer: UpdateOffer(
      version: '${remote.major}.${remote.minor}.${remote.patch}',
      assetName: picked.name,
      assetUrl: picked.url,
      checksumName: sums?.name,
      checksumUrl: sums?.url,
    ),
  );
}

enum _SourceFailure { down, rate }

/// Asks [preferred] first. A source that answers, even with "already current",
/// is kept. The other source is used only when the chosen one cannot be read,
/// and the message names the source that actually answered.
Future<UpdateCheck> findUpdate({
  required String current,
  required UpdateEndpoints endpoints,
  required UpdateSource preferred,
  required Future<String?> Function(Uri url) fetch,
  required String os,
  required String arch,
}) async {
  final order = preferred == UpdateSource.github
      ? const [UpdateSource.github, UpdateSource.gitea]
      : const [UpdateSource.gitea, UpdateSource.github];
  var sawRate = false;
  var sawDown = false;
  _SourceFailure? preferredFailure;
  for (var i = 0; i < order.length; i++) {
    final source = order[i];
    final outcome = await _readLatest(
      url: endpoints.latestFor(source),
      fetch: fetch,
      current: current,
      os: os,
      arch: arch,
    );
    final failure = outcome.failure;
    if (failure == null) {
      final check = outcome.check!;
      final fellBack = i > 0;
      return UpdateCheck(
        reachable: true,
        offer: check.offer,
        used: source,
        fellBack: fellBack,
        message: _withSource(
          check,
          _sourceClause(
            used: source,
            fellBack: fellBack,
            preferredFailure: preferredFailure,
          ),
        ),
      );
    }
    if (i == 0) {
      preferredFailure = failure;
    }
    if (failure == _SourceFailure.rate) {
      sawRate = true;
    } else {
      sawDown = true;
    }
  }
  return UpdateCheck(reachable: false, message: _bothFailed(sawRate, sawDown));
}

class _LatestOutcome {
  const _LatestOutcome.ok(this.check) : failure = null;
  const _LatestOutcome.fail(this.failure) : check = null;

  final UpdateCheck? check;
  final _SourceFailure? failure;
}

Future<_LatestOutcome> _readLatest({
  required String url,
  required Future<String?> Function(Uri url) fetch,
  required String current,
  required String os,
  required String arch,
}) async {
  String? body;
  try {
    body = await fetch(Uri.parse(url));
  } on UpdateFetchException catch (error) {
    if (error.rateLimited) {
      return const _LatestOutcome.fail(_SourceFailure.rate);
    }
    return const _LatestOutcome.fail(_SourceFailure.down);
  } on Object {
    return const _LatestOutcome.fail(_SourceFailure.down);
  }
  if (body == null) {
    return const _LatestOutcome.fail(_SourceFailure.down);
  }
  final check = interpretRelease(
    current: current,
    body: body,
    os: os,
    arch: arch,
  );
  if (!check.reachable) {
    return const _LatestOutcome.fail(_SourceFailure.down);
  }
  return _LatestOutcome.ok(check);
}

String _sourceClause({
  required UpdateSource used,
  required bool fellBack,
  required _SourceFailure? preferredFailure,
}) {
  final usedLabel = updateSourceLabel(used);
  if (!fellBack) {
    return '这次用的是 $usedLabel';
  }
  final preferredLabel = updateSourceLabel(
    used == UpdateSource.github ? UpdateSource.gitea : UpdateSource.github,
  );
  if (preferredFailure == _SourceFailure.rate) {
    return '$preferredLabel 暂时限制了请求次数，这次用的是 $usedLabel';
  }
  return '$preferredLabel 连不上，这次用的是 $usedLabel';
}

String _withSource(UpdateCheck check, String clause) {
  if (check.offer != null) {
    return '发现 ${check.offer!.version}。可以下载并覆盖安装。（$clause）';
  }
  if (check.message.isEmpty) {
    return clause;
  }
  return '${check.message}（$clause）';
}

String _bothFailed(bool sawRate, bool sawDown) {
  if (sawRate && sawDown) {
    return '所选更新源暂时限制了请求次数，另一个也连不上，没有检查到更新';
  }
  if (sawRate) {
    return 'YanJiu Git 和 GitHub 都暂时限制了请求次数，请稍后再试';
  }
  return 'YanJiu Git 和 GitHub 都连不上，没有检查到更新';
}
