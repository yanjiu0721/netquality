import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/center/catalog.dart';
import 'package:netquality/models/ip_family.dart';
import 'package:netquality/models/session_config.dart';
import 'package:netquality/models/target_history.dart';
import 'package:netquality/update/installer.dart';
import 'package:netquality/update/update_check.dart';

void main() {
  test('version comparison ignores a leading v and a build suffix', () {
    final current = SemVer.parse('1.1.3');
    expect(SemVer.parse('v1.1.4')!.isNewerThan(current!), isTrue);
    expect(SemVer.parse('1.1.3+6')!.isNewerThan(current), isFalse);
    expect(SemVer.parse('1.1.2')!.isNewerThan(current), isFalse);
    expect(SemVer.parse('1.2.0-rc.1')!.isNewerThan(current), isTrue);
  });

  test('the matching client archive is chosen and checksum files are recognized', () {
    const assets = [
      ReleaseFile(name: 'netquality-server-1.1.4-linux-amd64.tar.gz', url: 's'),
      ReleaseFile(name: 'netquality-client-1.1.4-linux-amd64.tar.gz', url: 'c'),
      ReleaseFile(name: 'SHA256SUMS', url: 'sum'),
    ];
    expect(
      pickClientAsset(assets, os: 'linux', arch: 'amd64'),
      'netquality-client-1.1.4-linux-amd64.tar.gz',
    );
    expect(looksLikeChecksum('SHA256SUMS'), isTrue);
    final check = interpretRelease(
      current: '1.1.3',
      os: 'linux',
      arch: 'amd64',
      body: '''
{
  "tag_name": "v1.1.4",
  "assets": [
    {"name": "netquality-client-1.1.4-linux-amd64.tar.gz", "browser_download_url": "https://example.test/client.tar.gz"},
    {"name": "SHA256SUMS", "browser_download_url": "https://example.test/SHA256SUMS"}
  ]
}
''',
    );
    expect(check.offer?.assetName, contains('linux-amd64'));
    expect(check.offer?.checksumName, 'SHA256SUMS');
  });

  test('github failure falls through to the spare source', () async {
    final check = await findUpdate(
      current: '1.1.3',
      preferred: UpdateSource.github,
      endpoints: const UpdateEndpoints(
        github: 'https://github.invalid/latest',
        gitea: 'https://git.invalid/latest',
      ),
      os: 'linux',
      arch: 'amd64',
      fetch: (url) async {
        if (url.host.contains('github')) {
          return null;
        }
        return '''
{"tag_name":"v1.1.9","assets":[
  {"name":"netquality-client-1.1.9-linux-amd64.tar.gz","browser_download_url":"https://example.test/a.tar.gz"}
]}
''';
      },
    );
    expect(check.offer?.version, '1.1.9');
    expect(check.used, UpdateSource.gitea);
    expect(check.fellBack, isTrue);
    expect(check.message, contains('GitHub'));
    expect(check.message, contains('YanJiu Git'));
  });

  test('history keeps the newest identical target and can delete or clear', () {
    const older = TargetEntry(
      host: '203.0.113.8',
      port: 443,
      profileId: 'http',
      httpUrl: 'https://203.0.113.8/a',
      method: 'GET',
      savedAtMs: 1,
    );
    const newer = TargetEntry(
      host: '203.0.113.8',
      port: 443,
      profileId: 'http',
      httpUrl: 'https://203.0.113.8/a',
      method: 'get',
      savedAtMs: 2,
    );
    final history = TargetHistory.empty
        .add(older)
        .add(
          const TargetEntry(
            host: 'example.com',
            port: 19090,
            profileId: 'nq-tcp',
            savedAtMs: 3,
          ),
        )
        .add(newer);
    expect(history.entries, hasLength(2));
    expect(history.entries.first.savedAtMs, 2);
    expect(history.entries.first.toJson().containsKey('token'), isFalse);
    final removed = history.removeAt(0);
    expect(removed.entries.single.host, 'example.com');
    expect(removed.clear().entries, isEmpty);

    var capped = TargetHistory.empty;
    for (var i = 0; i < 45; i++) {
      capped = capped.add(
        TargetEntry(
          host: 'h$i',
          port: i + 1,
          profileId: 'tcp-connect',
          savedAtMs: i,
        ),
      );
    }
    expect(capped.entries, hasLength(TargetHistory.maxEntries));
    expect(capped.entries.first.host, 'h44');
    final again = TargetHistory.decode(capped.encode());
    expect(again.entries.first.host, 'h44');
  });

  test('disabled families are filtered and a literal of that family is refused', () {
    final kept = filterAddresses(
      [
        InternetAddress('203.0.113.5'),
        InternetAddress('2001:db8::1'),
      ],
      v4: true,
      v6: false,
    );
    expect(kept.map((address) => address.address), ['203.0.113.5']);
    expect(familyRefusal('2001:db8::1', v4: true, v6: false), contains('IPv6'));
    expect(familyRefusal('203.0.113.5', v4: false, v6: true), contains('IPv4'));
    expect(familyRefusal('example.com', v4: false, v6: false), contains('都已关闭'));
    expect(
      familyRefusal('https://203.0.113.9/path', v4: false, v6: true),
      contains('IPv4'),
    );
  });

  test('a confidential catalog entry cannot keep an address that was sent by mistake', () {
    const secret = 'https://secret-node.internal:8443';
    final catalog = Catalog.parse('''
{
  "account": "lab",
  "group": "lab",
  "servers": [
    {
      "id": "secret-node",
      "name": "保密节点",
      "confidential": true,
      "controlUrl": "$secret",
      "credential": "node-token-should-not-leak"
    },
    {
      "id": "lab-node",
      "name": "实验室节点",
      "confidential": false,
      "controlUrl": "https://127.0.0.1:8443",
      "credential": "short-lived"
    }
  ]
}
''');
    final secretServer = catalog.servers.first;
    expect(secretServer.controlUrl, isEmpty);
    expect(secretServer.credential, isEmpty);
    expect(catalog.servers.last.controlUrl, 'https://127.0.0.1:8443');

    const link = CenterLink(id: 'c1', url: 'https://center.example', account: 'lab');
    var seq = 0;
    final merged = mergeCenterCatalog(
      existing: const [
        RemoteNode(id: 'manual', name: '手填', baseUrl: 'https://manual.example'),
      ],
      link: link,
      catalog: catalog,
      newId: () => 'new-${seq++}',
    );
    final hidden = merged.nodes.firstWhere((node) => node.serverId == 'secret-node');
    expect(hidden.baseUrl, isEmpty);
    expect(hidden.confidential, isTrue);
    expect(merged.credentials.containsKey(hidden.id), isFalse);
    expect(storedNodeHides(hidden, secret), isTrue);
    expect(storedNodeHides(hidden, 'node-token-should-not-leak'), isTrue);
    expect(merged.nodes.any((node) => node.id == 'manual'), isTrue);
    expect(renameNode(hidden, '别的名字').name, '保密节点');

    final again = SessionConfig.fromJson({
      ...SessionConfig.defaults.toJson(),
      'nodes': [hidden.toJson()],
    });
    expect(again.nodes.single.baseUrl, isEmpty);
  });

  test('checksum must mention the asset, and install copy stays inside the directory', () {
    final bytes = [1, 2, 3, 4];
    expect(checksumMatches('abc  other.bin\n', 'client.zip', bytes), isFalse);
    final digest = 'e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1';
    expect(checksumMatches('$digest  client.zip\n', 'client.zip', bytes), isFalse);
    final want = sha256.convert(bytes).toString();
    expect(checksumMatches('$want *client.zip\n', 'client.zip', bytes), isTrue);

    final root = Directory.systemTemp.createTempSync('nq-install');
    addTearDown(() => root.deleteSync(recursive: true));
    final extracted = Directory('${root.path}/extracted')..createSync();
    final install = Directory('${root.path}/install')..createSync();
    File('${extracted.path}/netquality').writeAsStringSync('new');
    File('${install.path}/kept.txt').writeAsStringSync('stay');
    copyIntoInstall(extracted, install);
    expect(File('${install.path}/netquality').readAsStringSync(), 'new');
    expect(File('${install.path}/kept.txt').readAsStringSync(), 'stay');
  });
}
