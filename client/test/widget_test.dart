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
      nodes: [RemoteNode(id: 'n1', name: '机房', baseUrl: 'https://probe.example:8443')],
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
}
