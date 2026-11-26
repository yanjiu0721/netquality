import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/main.dart';
import 'package:netquality/models/session_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('opens on local source with an empty chart', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    expect(find.text('网络质量探测'), findsOneWidget);
    expect(find.text('探测来源'), findsOneWidget);
    expect(find.text('本机'), findsWidgets);
    expect(find.text('远程节点'), findsWidgets);
    expect(find.text('开始探测'), findsOneWidget);
    expect(find.text('暂无已完成的探测'), findsNWidgets(2));
    expect(find.textContaining('127.0.0.1'), findsWidgets);
  });

  test('settings round trip keeps the node and drops nothing secret into json keys', () {
    const config = SessionConfig(
      remote: true,
      nodeId: 'n1',
      nodes: [
        RemoteNode(id: 'n1', name: '机房', baseUrl: 'https://probe.example:8443'),
      ],
      host: '203.0.113.8',
      port: 25565,
      profileId: 'minecraft-java',
      intervalMs: 300,
      timeoutMs: 1000,
      durationSec: 60,
      packetSize: 128,
      dnsName: 'example.com',
      payloadHex: '',
      expectHex: '',
    );
    final again = SessionConfig.fromJson(config.toJson());
    expect(again.host, '203.0.113.8');
    expect(again.profileId, 'minecraft-java');
    expect(again.node?.name, '机房');
    expect(again.toJson().containsKey('token'), isFalse);
    expect(again.toJson().containsKey('nodeToken'), isFalse);
    expect(SessionConfig.defaults.validate(), isNull);
  });

  testWidgets(
    'profile default port updates until the user types another port',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const NetQualityApp());
      await tester.pumpAndSettle();

      expect(find.text('合作反射 TCP 默认 19090'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('profile')));
      await tester.tap(find.byKey(const Key('profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('合作反射 UDP').last);
      await tester.pumpAndSettle();
      expect(find.text('19091'), findsWidgets);
      expect(find.text('合作反射 UDP 默认 19091'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('port-field')), '25565');
      await tester.tap(find.byKey(const Key('profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('合作反射 TCP').last);
      await tester.pumpAndSettle();
      expect(find.text('25565'), findsOneWidget);
    },
  );

  testWidgets('HTTP mode uses a URL, a 5 second timeout, and no port field', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('profile')));
    await tester.tap(find.byKey(const Key('profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HTTP').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('port-field')), findsNothing);
    expect(find.text('HTTP 默认 5000 毫秒'), findsOneWidget);
    expect(find.text('5000'), findsWidgets);
    expect(
      find.text('只填主机名或 IP 时按 http:// 和端口 80。完整网址使用其中的协议、端口和路径。'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('target-field')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('timeout-field')), '2000');
    await tester.tap(find.byKey(const Key('profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合作反射 UDP').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('port-field')), findsOneWidget);
    expect(find.text('19091'), findsWidgets);
    expect(find.text('2000'), findsOneWidget);
    expect(find.text('HTTP 默认 5000 毫秒'), findsNothing);
  });

  testWidgets('editing a node keeps its id and does not reveal the token', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('远程节点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('node-name')), '机房');
    await tester.enterText(
      find.byKey(const Key('node-url')),
      'http://127.0.0.1:8443',
    );
    await tester.enterText(find.byKey(const Key('node-token')), 'saved-secret');
    await tester.tap(find.byKey(const Key('node-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final token = tester.widget<TextField>(find.byKey(const Key('node-token')));
    expect(token.controller?.text, isEmpty);
    expect(find.text('saved-secret'), findsNothing);
    await tester.enterText(find.byKey(const Key('node-name')), '机房乙');
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(find.textContaining('机房乙'), findsWidgets);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('netquality.settings.v2') ?? '';
    expect(raw, contains('机房乙'));
    expect(raw, isNot(contains('saved-secret')));
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final nodes = decoded['nodes'] as List<dynamic>;
    expect(nodes, hasLength(1));
    final node = nodes.single as Map<String, dynamic>;
    expect(node['name'], '机房乙');
    expect(node['baseUrl'], 'http://127.0.0.1:8443');
    expect(decoded['nodeId'], node['id']);
  });

  testWidgets('guide and history screens use the real versions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('指标说明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有协议应答'), findsWidgets);
    await tester.scrollUntilVisible(find.text('选址失败和正式丢包'), 200);
    expect(find.text('选址失败和正式丢包'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('RFC 3550'), 200);
    expect(find.textContaining('RFC 3550'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新历史'));
    await tester.pumpAndSettle();
    expect(find.text('网络质量探测 1.1.2'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('网络质量探测 1.1.1'), 200);
    expect(find.text('网络质量探测 1.1.1'), findsOneWidget);
    expect(find.textContaining('言灸'), findsOneWidget);
    expect(find.textContaining('v1.1.1'), findsWidgets);
    expect(find.text('网络质量探测 1.1.0'), findsNothing);
  });
}
