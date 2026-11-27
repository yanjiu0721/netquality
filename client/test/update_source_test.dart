import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/content/release_history.dart';
import 'package:netquality/main.dart';
import 'package:netquality/models/session_config.dart';
import 'package:netquality/storage/app_store.dart';
import 'package:netquality/update/release_feed.dart';
import 'package:netquality/update/update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _endpoints = UpdateEndpoints(
  github: 'https://github.example/repos/yanjiu0721/netquality/releases/latest',
  gitea: 'https://git.example/api/v1/repos/YanJiu/netquality/releases/latest',
);

const _bundledOnly = ReleaseEntry(
  version: '0.9.1',
  title: '安装包里的说明',
  source: 'bundle',
  points: ['只在安装包里'],
);

const _feed = '''
[
  {
    "tag_name": "v1.1.9",
    "name": "网络质量探测 1.1.9",
    "draft": false,
    "prerelease": false,
    "published_at": "2026-12-01T08:00:00Z",
    "body": "# 网络质量探测 1.1.9\\n\\n## 在线历史\\n\\n- 可以读取比已安装版本更新的说明\\n\\n见 [发布页](https://example.test/r)。"
  },
  {
    "tag_name": "v1.1.3",
    "name": "网络质量探测 1.1.3",
    "published_at": "2026-11-21T21:51:01+08:00",
    "body": "构建号 6。"
  },
  {
    "tag_name": "v1.2.0-rc.1",
    "name": "网络质量探测 1.2.0 rc",
    "prerelease": true,
    "published_at": "2026-12-02T00:00:00Z",
    "body": "预发布说明"
  },
  {
    "tag_name": "v9.9.9",
    "name": "不要出现的草稿",
    "draft": true,
    "body": "秘密"
  },
  {
    "tag_name": "nightly",
    "name": "不是版本号",
    "body": "跳过"
  }
]
''';

const _linuxAsset = '''
{"tag_name":"v1.1.9","assets":[
  {"name":"netquality-client-1.1.9-linux-amd64.tar.gz","browser_download_url":"https://example.test/a.tar.gz"}
]}
''';

void main() {
  test('the saved update source defaults to YanJiu Git', () {
    expect(SessionConfig.defaults.updateSource, 'gitea');
    expect(parseUpdateSource(null), UpdateSource.gitea);
    expect(parseUpdateSource('github'), UpdateSource.github);
    expect(parseUpdateSource('GitHub'), UpdateSource.gitea);
    final stored = SessionConfig.fromJson({
      ...SessionConfig.defaults.toJson(),
      'updateSource': 'github',
    });
    expect(stored.updateSource, 'github');
    expect(stored.toJson()['updateSource'], 'github');
    final unknown = SessionConfig.fromJson({
      ...SessionConfig.defaults.toJson(),
      'updateSource': 'somewhere-else',
    });
    expect(unknown.updateSource, 'gitea');
    final missing = SessionConfig.defaults.toJson()..remove('updateSource');
    expect(SessionConfig.fromJson(missing).updateSource, 'gitea');
  });

  test('env overrides replace only a non-empty release URL', () {
    expect(updateEndpoints().github, UpdateEndpoints.githubDefault);
    expect(updateEndpoints().gitea, UpdateEndpoints.giteaDefault);
    expect(
      updateEndpoints(githubApi: '  ').github,
      UpdateEndpoints.githubDefault,
    );
    final overridden = updateEndpoints(
      githubApi: ' https://example.test/latest ',
      giteaApi: 'https://git.example/latest',
    );
    expect(overridden.github, 'https://example.test/latest');
    expect(overridden.gitea, 'https://git.example/latest');
  });

  test(
    'a chosen source that answers is named and the other is not called',
    () async {
      final hosts = <String>[];
      final check = await findUpdate(
        current: '1.1.3',
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        os: 'linux',
        arch: 'amd64',
        fetch: (url) async {
          hosts.add(url.host);
          return _linuxAsset;
        },
      );
      expect(hosts, ['git.example']);
      expect(check.used, UpdateSource.gitea);
      expect(check.fellBack, isFalse);
      expect(check.offer?.version, '1.1.9');
      expect(check.offer?.assetUrl, 'https://example.test/a.tar.gz');
      expect(check.message, contains('这次用的是 YanJiu Git'));
      expect(check.message, isNot(contains('改用')));
    },
  );

  test(
    'an unreachable chosen source falls back and names the one that worked',
    () async {
      final check = await findUpdate(
        current: '1.1.3',
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        os: 'linux',
        arch: 'amd64',
        fetch: (url) async => url.host == 'git.example' ? null : _linuxAsset,
      );
      expect(check.used, UpdateSource.github);
      expect(check.fellBack, isTrue);
      expect(check.message, contains('YanJiu Git 连不上'));
      expect(check.message, contains('这次用的是 GitHub'));
    },
  );

  test(
    'a rate limit falls back and the message says which source was used',
    () async {
      final check = await findUpdate(
        current: '1.1.3',
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        os: 'linux',
        arch: 'amd64',
        fetch: (url) async {
          if (url.host == 'git.example') {
            throw const UpdateFetchException(rateLimited: true, status: 429);
          }
          return _linuxAsset;
        },
      );
      expect(check.used, UpdateSource.github);
      expect(check.message, contains('暂时限制了请求次数'));
      expect(check.message, contains('这次用的是 GitHub'));
    },
  );

  test('both sources down, or both rate limited, stay unnamed', () async {
    final down = await findUpdate(
      current: '1.1.3',
      preferred: UpdateSource.gitea,
      endpoints: _endpoints,
      os: 'linux',
      arch: 'amd64',
      fetch: (_) async => null,
    );
    expect(down.reachable, isFalse);
    expect(down.used, isNull);
    expect(down.message, 'YanJiu Git 和 GitHub 都连不上，没有检查到更新');

    final limited = await findUpdate(
      current: '1.1.3',
      preferred: UpdateSource.github,
      endpoints: _endpoints,
      os: 'linux',
      arch: 'amd64',
      fetch: (_) async {
        throw const UpdateFetchException(rateLimited: true, status: 403);
      },
    );
    expect(limited.message, contains('都暂时限制了请求次数'));
  });

  test(
    'rate-limit responses are recognized without treating every 403 as one',
    () {
      expect(isReleaseRateLimited(status: 429, body: ''), isTrue);
      expect(
        isReleaseRateLimited(status: 403, rateLimitRemaining: '0', body: 'no'),
        isTrue,
      );
      expect(
        isReleaseRateLimited(
          status: 403,
          body: 'API rate limit exceeded for 1.2.3.4',
        ),
        isTrue,
      );
      expect(isReleaseRateLimited(status: 403, body: 'forbidden'), isFalse);
      expect(isReleaseRateLimited(status: 200, body: 'rate limit'), isFalse);
    },
  );

  test('list URLs follow the latest override and the forge page size', () {
    final gitea = releaseListUri(
      _endpoints.gitea,
      source: UpdateSource.gitea,
      page: 2,
      pageSize: 50,
    );
    expect(gitea.path, '/api/v1/repos/YanJiu/netquality/releases');
    expect(gitea.queryParameters['limit'], '50');
    expect(gitea.queryParameters['page'], '2');
    expect(gitea.queryParameters.containsKey('per_page'), isFalse);

    final github = releaseListUri(
      _endpoints.github,
      source: UpdateSource.github,
      page: 1,
      pageSize: 100,
    );
    expect(github.path, '/repos/yanjiu0721/netquality/releases');
    expect(github.queryParameters['per_page'], '100');
    expect(github.queryParameters.containsKey('limit'), isFalse);
  });

  test('a release list keeps newer published notes and drops drafts', () async {
    final result = await syncReleaseHistory(
      preferred: UpdateSource.gitea,
      endpoints: _endpoints,
      bundled: const [_bundledOnly],
      fetch: (url) async {
        expect(url.host, 'git.example');
        return _feed;
      },
    );
    expect(result.origin, HistoryOrigin.remote);
    expect(result.used, UpdateSource.gitea);
    expect(result.entries.map((entry) => entry.version), [
      '1.2.0',
      '1.1.9',
      '1.1.3',
    ]);
    expect(result.entries.map((entry) => entry.tag), [
      'v1.2.0-rc.1',
      'v1.1.9',
      'v1.1.3',
    ]);
    final newest = result.entries[1];
    expect(newest.title, '网络质量探测 1.1.9');
    expect(newest.published, '2026-12-01');
    expect(newest.points, contains('可以读取比已安装版本更新的说明'));
    expect(newest.points, contains('见 发布页（https://example.test/r）。'));
    expect(newest.points, isNot(contains('网络质量探测 1.1.9')));
    expect(result.entries.first.source, contains('预发布'));
    expect(result.entries.first.published, '2026-12-02');
    expect(
      result.entries.map((entry) => entry.title),
      isNot(contains('不要出现的草稿')),
    );
    expect(
      result.entries.map((entry) => entry.version),
      isNot(contains('0.9.1')),
    );
    expect(
      result.entries.map((entry) => entry.version),
      isNot(contains('1.1.0')),
    );
    expect(result.note, contains('已从 YanJiu Git 同步'));
    expect(result.note, contains('比当前安装更新的发布也会列在这里'));
    final again = decodeReleaseCache(result.cacheJson);
    expect(again?.source, 'gitea');
    expect(again?.entries.map((entry) => entry.version), [
      '1.2.0',
      '1.1.9',
      '1.1.3',
    ]);
  });

  test('pages are followed, and a full last page says the list may be short', () async {
    final pages = <int>[];
    final result = await syncReleaseHistory(
      preferred: UpdateSource.github,
      endpoints: _endpoints,
      githubPageSize: 1,
      fetch: (url) async {
        expect(url.host, 'github.example');
        expect(url.queryParameters['per_page'], '1');
        expect(url.path, isNot(endsWith('/latest')));
        final page = int.parse(url.queryParameters['page']!);
        pages.add(page);
        if (page == 1) {
          return '[{"tag_name":"v1.1.9","name":"新","published_at":"2026-12-01T00:00:00Z","body":"新说明"}]';
        }
        if (page == 2) {
          return '[{"tag_name":"v1.1.3","name":"旧","published_at":"2026-11-21T00:00:00Z","body":"旧说明"}]';
        }
        return '[]';
      },
    );
    expect(pages, [1, 2, 3]);
    expect(result.entries.map((entry) => entry.version), ['1.1.9', '1.1.3']);

    final capped = await syncReleaseHistory(
      preferred: UpdateSource.gitea,
      endpoints: _endpoints,
      pageLimit: 1,
      giteaPageSize: 1,
      fetch: (_) async => '[{"tag_name":"v1.1.9","name":"新","body":"只有第一页"}]',
    );
    expect(capped.entries, hasLength(1));
    expect(capped.note, contains('没有取完'));
  });

  test(
    'history uses the spare source when the chosen one cannot be read',
    () async {
      final result = await syncReleaseHistory(
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        bundled: const [_bundledOnly],
        fetch: (url) async {
          if (url.host == 'git.example') {
            throw const UpdateFetchException(rateLimited: true, status: 429);
          }
          return _feed;
        },
      );
      expect(result.used, UpdateSource.github);
      expect(result.note, contains('暂时限制了请求次数'));
      expect(result.note, contains('这次改用了 GitHub'));
      expect(result.entries.first.version, '1.2.0');
      expect(result.entries.any((entry) => entry.version == '0.9.1'), isFalse);
    },
  );

  test(
    'a failed sync keeps the cache, then the bundled notes, and says so',
    () async {
      String? stored;
      final fresh = await syncAndStore(
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        readCache: () async => null,
        writeCache: (json) async => stored = json,
        fetch: (url) async => url.host == 'git.example' ? _feed : null,
      );
      expect(fresh.origin, HistoryOrigin.remote);
      expect(stored, isNotNull);

      final cached = await syncReleaseHistory(
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        cachedJson: stored,
        bundled: const [_bundledOnly],
        fetch: (_) async => null,
      );
      expect(cached.origin, HistoryOrigin.cache);
      expect(cached.entries.first.version, '1.2.0');
      expect(cached.note, contains('可能不是最新'));
      expect(cached.note, contains('上次从 YanJiu Git 保存的列表'));
      expect(cached.entries.any((entry) => entry.version == '0.9.1'), isFalse);

      final bundled = await syncReleaseHistory(
        preferred: UpdateSource.github,
        endpoints: _endpoints,
        cachedJson: '{',
        bundled: const [_bundledOnly],
        fetch: (_) async => null,
      );
      expect(bundled.origin, HistoryOrigin.bundled);
      expect(bundled.entries, [_bundledOnly]);
      expect(bundled.note, contains('没有保存过在线列表'));
      expect(bundled.note, contains('安装包里的说明'));
      expect(bundled.note, contains('可能不是最新'));

      final limited = await syncReleaseHistory(
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        cachedJson: null,
        bundled: const [_bundledOnly],
        fetch: (_) async {
          throw const UpdateFetchException(rateLimited: true, status: 429);
        },
      );
      expect(limited.origin, HistoryOrigin.bundled);
      expect(limited.note, contains('暂时限制了请求次数'));
      expect(limited.note, contains('可能不是最新'));
    },
  );

  test(
    'an empty published list is kept and does not invent bundled versions',
    () async {
      final result = await syncReleaseHistory(
        preferred: UpdateSource.gitea,
        endpoints: _endpoints,
        bundled: const [_bundledOnly],
        fetch: (_) async => '[]',
      );
      expect(result.origin, HistoryOrigin.remote);
      expect(result.entries, isEmpty);
      expect(result.note, contains('没有已发布的版本'));
      expect(result.cacheJson, isNotNull);
    },
  );

  testWidgets('settings defaults to YanJiu Git and remembers GitHub', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    await _openSettings(tester);
    expect(_selectedSource(tester), {UpdateSource.gitea});
    expect(find.textContaining('先试 GitHub'), findsNothing);
    expect(find.textContaining('先问 GitHub'), findsNothing);
    expect(find.textContaining('结果里会写明这次实际用的是哪一个'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('update-source')),
        matching: find.text('GitHub'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_selectedSource(tester), {UpdateSource.github});

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('netquality.settings.v2'),
      contains('"updateSource":"github"'),
    );
    final loaded = await AppStore().load();
    expect(loaded.config.updateSource, 'github');
    expect(parseUpdateSource(loaded.config.updateSource), UpdateSource.github);
  });

  testWidgets('history shows a cached release newer than this install', (
    tester,
  ) async {
    final cache = encodeReleaseCache(
      source: 'gitea',
      entries: const [
        ReleaseEntry(
          version: '9.9.9',
          tag: 'v9.9.9',
          title: '网络质量探测 9.9.9',
          source: '来自 YanJiu Git · 标签 v9.9.9',
          published: '2026-12-01',
          points: ['比已安装的版本新'],
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({releaseHistoryCacheKey: cache});
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新历史'));
    await tester.pumpAndSettle();

    expect(find.text('网络质量探测 9.9.9'), findsOneWidget);
    expect(find.text('比当前安装的 1.1.4 新'), findsOneWidget);
    expect(find.text('网络质量探测 1.1.1'), findsNothing);
    expect(find.textContaining('已经发布的 1.1.2 和 1.1.3'), findsOneWidget);
    expect(find.textContaining('可能不是最新'), findsNothing);
  });
}

Set<UpdateSource> _selectedSource(WidgetTester tester) {
  return tester
      .widget<SegmentedButton<UpdateSource>>(
        find.byKey(const Key('update-source')),
      )
      .selected;
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('设置'));
  await tester.pumpAndSettle();
}
