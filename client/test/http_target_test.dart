// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/models/http_target.dart';
import 'package:netquality/models/port_field.dart';
import 'package:netquality/models/session_config.dart';
import 'package:netquality/probe/http_helper.dart';
import 'package:netquality/probe/probe_controller.dart';

void main() {
  test(
    'bare hosts become http on port 80 and full URLs keep their own parts',
    () {
      final bare = parseHttpTarget('rxsend.cn');
      expect(bare, isNotNull);
      expect(bare!.url, 'http://rxsend.cn/');
      expect(bare.port, 80);
      expect(bare.scheme, 'http');

      final path = parseHttpTarget('example.com/path?q=1');
      expect(path!.url, 'http://example.com/path?q=1');
      expect(path.port, 80);

      final explicit = parseHttpTarget('example.com:8080/a');
      expect(explicit!.url, 'http://example.com:8080/a');
      expect(explicit.port, 8080);
      expect(explicit.scheme, 'http');

      final full = parseHttpTarget('https://www.cause-by-siky.top:2025/');
      expect(full!.url, 'https://www.cause-by-siky.top:2025/');
      expect(full.port, 2025);
      expect(full.scheme, 'https');
      expect(full.host, 'www.cause-by-siky.top');

      final httpsDefault = parseHttpTarget('https://example.com/path');
      expect(httpsDefault!.url, 'https://example.com/path');
      expect(httpsDefault.port, 443);

      final httpDefault = parseHttpTarget('http://example.com/path');
      expect(httpDefault!.url, 'http://example.com/path');
      expect(httpDefault.port, 80);

      final v6 = parseHttpTarget('[2001:db8::1]');
      expect(v6!.url, 'http://[2001:db8::1]/');
      expect(v6.port, 80);
      expect(v6.host, '2001:db8::1');

      final v6Port = parseHttpTarget('[2001:db8::1]:8080/a');
      expect(v6Port!.url, 'http://[2001:db8::1]:8080/a');
      expect(v6Port.port, 8080);

      final bareV6 = parseHttpTarget('2001:db8::1');
      expect(bareV6!.url, 'http://[2001:db8::1]/');
      expect(bareV6.port, 80);
    },
  );

  test('invalid HTTP targets explain the problem in Chinese', () {
    expect(httpTargetError(''), '请填写目标地址');
    expect(httpTargetError('   '), '请填写目标地址');
    expect(httpTargetError('ftp://example.com'), contains('http/https'));
    expect(httpTargetError('https://example.com:99999/'), contains('端口'));
    expect(httpTargetError('example.com:70000'), contains('端口'));
    expect(parseHttpTarget('ftp://example.com'), isNull);
  });

  test('HTTP validation ignores the separate port and other profiles still require one', () {
    final url = _config(
      host: 'https://www.cause-by-siky.top:2025/path',
      port: 0,
    );
    expect(url.validate(), isNull);
    expect(url.httpTarget!.port, 2025);
    expect(url.httpTarget!.url, 'https://www.cause-by-siky.top:2025/path');

    final bare = _config(host: 'rxsend.cn', port: 19090);
    expect(bare.validate(), isNull);
    expect(bare.httpTarget!.url, 'http://rxsend.cn/');
    expect(bare.httpTarget!.port, 80);

    final bad = _config(host: 'ftp://example.com', port: 443);
    expect(bad.validate(), contains('http/https'));

    final family = _config(
      host: 'https://203.0.113.9/path',
      port: 0,
      allow4: false,
    );
    expect(family.validate(), contains('IPv4'));

    final tcp = _config(host: '203.0.113.8', port: 0, profileId: 'tcp-connect');
    expect(tcp.validate(), contains('端口'));
    expect(tcp.httpTarget, isNull);
  });

  test('HTTP timeout default is 5 seconds and a typed timeout stays', () {
    expect(timeoutDefaultFor('http'), 5000);
    expect(timeoutDefaultFor('nq-tcp'), 1000);
    expect(
      timeoutAfterProfileChange(
        current: '1000',
        previousDefault: 1000,
        nextDefault: 5000,
      ),
      '5000',
    );
    expect(
      timeoutAfterProfileChange(
        current: '2000',
        previousDefault: 1000,
        nextDefault: 5000,
      ),
      '2000',
    );
    expect(
      timeoutAfterProfileChange(
        current: '5000',
        previousDefault: 5000,
        nextDefault: 1000,
      ),
      '1000',
    );
    expect(
      timeoutAfterProfileChange(
        current: '',
        previousDefault: 1000,
        nextDefault: 5000,
      ),
      '5000',
    );
  });

  test(
    'starting local HTTP without a helper does not open a loss run',
    () async {
      locateProbeHelperOverride = () => null;
      addTearDown(() => locateProbeHelperOverride = null);
      final controller = ProbeController();
      addTearDown(controller.dispose);
      await controller.start(
        _config(host: 'rxsend.cn', port: 443),
        nodeToken: '',
        echoToken: '',
      );
      expect(controller.view.running, isFalse);
      expect(controller.view.phase, '无法开始');
      expect(controller.view.banner, helperMissingNote);
      expect(controller.view.banner, contains('远程节点'));
      expect(controller.view.samples, isEmpty);
      expect(controller.view.summary.completed, 0);
      expect(controller.view.report, isNull);

      final started = DateTime.now();
      await controller.start(
        _config(host: 'https://www.cause-by-siky.top:2025/', port: 9),
        nodeToken: '',
        echoToken: '',
      );
      expect(DateTime.now().difference(started).inSeconds, lessThan(2));
      expect(controller.view.running, isFalse);
      expect(controller.view.report, isNull);
      expect(controller.view.summary.completed, 0);
    },
  );

  test(
    'a missing local helper fails immediately and names the remote source',
    () async {
      final message = await localHttpBlockedReason(
        binary: '/no/such/netquality-reflector',
      );
      expect(message, helperMissingNote);
      expect(message, contains('远程节点'));
      expect(message, contains('没有开始'));
    },
  );

  test('a helper that cannot be executed fails immediately', () async {
    final dir = Directory.systemTemp.createTempSync('nq-helper');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/netquality-reflector')
      ..writeAsStringSync('not a binary');
    final message = await localHttpBlockedReason(binary: file.path);
    expect(message, helperStartFailedNote);
    expect(message, contains('远程节点'));
  });
}

SessionConfig _config({
  required String host,
  required int port,
  String profileId = 'http',
  bool allow4 = true,
}) {
  return SessionConfig(
    remote: false,
    nodeId: '',
    nodes: const [],
    host: host,
    port: port,
    profileId: profileId,
    intervalMs: 300,
    timeoutMs: 5000,
    durationSec: 60,
    packetSize: 128,
    dnsName: 'example.com',
    payloadHex: '',
    expectHex: '',
    allowIPv4: allow4,
  );
}
