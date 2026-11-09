import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/metrics/sample_book.dart';
import 'package:netquality/models/session_config.dart';
import 'package:netquality/probe/game_codec.dart';
import 'package:netquality/probe/remote_client.dart';

void main() {
  test('pending work is not a rate, and connect failure is not probe loss', () {
    final book = SampleBook('nq-tcp');
    expect(book.summary().probeLossPct, isNull);
    expect(book.summary().completed, 0);
    book.add(
      const Outcome(status: Outcome.refused, kind: Outcome.connect, reconnect: true),
    );
    expect(book.summary().probeLossPct, isNull);
    expect(book.summary().reconnects, 1);
    book.add(const Outcome(status: Outcome.timeout, kind: Outcome.probe));
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 1));
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 2));
    book.add(const Outcome(status: Outcome.ok, kind: Outcome.probe, rttMs: 1.5));
    expect(book.summary().probeLossPct, 25);
    expect(book.summary().jitterMs, closeTo(0.08984375, 0.000001));
  });

  test('generic udp silence is unknown, not loss', () {
    final book = SampleBook('udp-generic');
    book.add(const Outcome(status: Outcome.unknown, kind: Outcome.query));
    final summary = book.summary();
    expect(summary.probeLossPct, isNull);
    expect(summary.unknownPct, 100);
  });

  test('node url rejects embedded secrets and job body keeps tokens apart', () {
    expect(normalizeNodeUrl('https://user:secret@probe.example/node'), isNull);
    expect(
      normalizeNodeUrl('https://probe.example:8443/nq?token=secret'),
      'https://probe.example:8443/nq',
    );
    expect(normalizeNodeUrl('http://127.0.0.1:8443'), 'http://127.0.0.1:8443');
    const body = ProbeBody(
      target: '203.0.113.10',
      port: 19090,
      profile: 'nq-tcp',
      intervalMs: 300,
      timeoutMs: 1000,
      durationSec: 30,
      packetSize: 128,
      echoToken: 'echo-secret',
      dnsName: '',
      payloadHex: '',
      expectHex: '',
    );
    final json = body.toJson();
    expect(json.containsKey('nodeToken'), isFalse);
    expect(json['echoToken'], 'echo-secret');
    expect(jsonEncodeContainsToken(json), isFalse);
  });

  test('minecraft and raknet builders match the protocol', () {
    final handshake = javaHandshake('127.0.0.1', 25565);
    expect(handshake.sublist(2, 4), [0xff, 0x05]);
    final status = minecraftStatusDetail(
      '{"version":{"name":"1.21.1"},"players":{"online":3,"max":20},"description":{"text":"Hello","extra":[{"text":"!"}]}}',
    );
    expect(status['motd'], 'Hello!');
    expect(status['version'], '1.21.1');
    expect(status['players'], '3/20');

    const motd = 'MCPE;Bed;844;1.21.50;1;10;0;';
    final pong = Uint8List.fromList([
      0x1c,
      0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
      0, 0, 0, 0, 0, 0, 0, 99,
      ...rakMagic,
      0, motd.length,
      ...motd.codeUnits,
    ]);
    final detail = parseRakPong(pong, 0x1122334455667788);
    expect(detail?['motd'], 'Bed');
    expect(detail?['version'], '1.21.50');
    expect(detail?['players'], '1/10');
    final bad = Uint8List.fromList(pong);
    bad[17] = 0x11;
    expect(parseRakPong(bad, 0x1122334455667788), isNull);
    final query = dnsQuery(7, 'example.com');
    expect(query[0], 0);
    expect(query[1], 7);
    expect((query[2] & 0x80), 0);
  });
}

bool jsonEncodeContainsToken(Map<String, Object?> json) {
  return json.keys.contains('nodeToken') || json.values.contains('node-control-secret');
}
