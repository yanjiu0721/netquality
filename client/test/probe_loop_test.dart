import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/metrics/sample_book.dart';
import 'package:netquality/probe/game_codec.dart';
import 'package:netquality/probe/probe_loop.dart';
import 'package:netquality/probe/remote_client.dart';

late String binary;

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('nq-node');
    binary = '${dir.path}/netquality-reflector';
    final serverDir = Directory('server').existsSync() ? 'server' : '../server';
    final build = await Process.run('go', [
      'build',
      '-o',
      binary,
      '.',
    ], workingDirectory: serverDir);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
  });

  test('local nq tcp and udp get real rtt and do not call connect failure loss', () async {
    final reflector = await _reflector();
    addTearDown(() => reflector.process.kill());
    final tcp = await _collect(
      ProbeRequest(
        host: '127.0.0.1',
        port: reflector.tcp,
        profileId: 'nq-tcp',
        interval: const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 800),
        packetSize: 80,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 2,
    );
    expect(tcp.last.status, Outcome.ok);
    expect(tcp.last.rttMs, greaterThan(0));
    expect(tcp.last.summary.probeLossPct, 0);

    final udp = await _collect(
      ProbeRequest(
        host: '127.0.0.1',
        port: reflector.udp,
        profileId: 'nq-udp',
        interval: const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 800),
        packetSize: 80,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 1,
    );
    expect(udp.single.status, Outcome.ok);
    expect(udp.single.summary.probeLossPct, 0);

    final refused = await _collect(
      ProbeRequest(
        host: '127.0.0.1',
        port: 1,
        profileId: 'tcp-connect',
        interval: const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 400),
        packetSize: 64,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 1,
    );
    expect(refused.single.status, Outcome.refused);
    expect(refused.single.summary.failurePct, 100);
    expect(refused.single.summary.probeLossPct, isNull);
  });

  test('silence is unknown, games answer, and a remote node measures rtt', () async {
    final hole = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(hole.close);
    hole.listen((event) {
      if (event == RawSocketEvent.read) {
        hole.receive();
      }
    });
    final unknown = await _collect(
      ProbeRequest(
        host: '127.0.0.1',
        port: hole.port,
        profileId: 'udp-generic',
        interval: const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 200),
        packetSize: 16,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 1,
    );
    expect(unknown.single.status, Outcome.unknown);
    expect(unknown.single.summary.probeLossPct, isNull);
    expect(unknown.single.summary.unknownPct, 100);
    expect(unknown.single.detail['address'], '127.0.0.1');

    final java = await _javaServer();
    addTearDown(java.close);
    final javaSample = await _collect(
      ProbeRequest(
        host: '127.0.0.1',
        port: java.port,
        profileId: 'minecraft-java',
        interval: const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 800),
        packetSize: 64,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 1,
    );
    expect(javaSample.single.status, Outcome.ok);
    expect(javaSample.single.detail['motd'], 'Hello');
    expect(javaSample.single.rttMs, greaterThan(0));
    expect(javaSample.single.summary.failurePct, 0);

    final bedrock = await _bedrockServer();
    addTearDown(bedrock.close);
    final bedrockSample = await _collect(
      ProbeRequest(
        host: '127.0.0.1',
        port: bedrock.port,
        profileId: 'minecraft-bedrock',
        interval: const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 800),
        packetSize: 64,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 1,
    );
    expect(bedrockSample.single.status, Outcome.ok);
    expect(bedrockSample.single.detail['motd'], 'Bed');

    final node = await _node();
    addTearDown(node.kill);
    final samples = <ProbeSample>[];
    final remote = RemoteProbe();
    final done = Completer<void>();
    unawaited(() async {
      try {
        await remote.run(
          baseUrl: 'http://127.0.0.1:${node.control}',
          nodeToken: '',
          body: ProbeBody(
            target: '127.0.0.1',
            port: node.udp,
            profile: 'nq-udp',
            intervalMs: 200,
            timeoutMs: 800,
            durationSec: 3,
            packetSize: 80,
            echoToken: '',
            dnsName: '',
            payloadHex: '',
            expectHex: '',
          ),
          onSample: (sample) {
            samples.add(sample);
            if (samples.length == 1 && !done.isCompleted) {
              done.complete();
            }
          },
          cancelled: () => done.isCompleted,
        );
      } finally {
        if (!done.isCompleted) {
          done.complete();
        }
      }
    }());
    await done.future.timeout(const Duration(seconds: 5));
    await remote.stop('');
    expect(samples, isNotEmpty);
    expect(samples.first.status, Outcome.ok);
    expect(samples.first.rttMs, greaterThan(0));
    expect(samples.first.summary.probeLossPct, 0);
  });

  test('plain udp leaves a silent address and keeps one that answers', () async {
    final drop = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(drop.close);
    final port = drop.port;
    drop.listen((event) {
      if (event == RawSocketEvent.read) {
        drop.receive();
      }
    });
    final RawDatagramSocket echo;
    try {
      echo = await RawDatagramSocket.bind(InternetAddress.loopbackIPv6, port);
    } on SocketException {
      markTestSkipped('IPv6 loopback is not available');
      return;
    }
    addTearDown(echo.close);
    echo.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = echo.receive();
      if (datagram == null) {
        return;
      }
      echo.send(datagram.data, datagram.address, datagram.port);
    });

    final seen = <String>[];
    final samples = await _collect(
      ProbeRequest(
        host: 'example.test',
        port: port,
        profileId: 'udp-generic',
        interval: const Duration(milliseconds: 40),
        timeout: const Duration(milliseconds: 250),
        packetSize: 16,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 2,
      loop: ProbeLoop(
        lookup: (host) async {
          expect(host, 'example.test');
          return [InternetAddress('127.0.0.1'), InternetAddress('::1')];
        },
        onEndpoint: (address) => seen.add(address.address),
      ),
    );
    expect(samples.first.status, Outcome.unknown);
    expect(samples.first.detail['address'], '127.0.0.1');
    expect(samples.last.status, Outcome.ok);
    expect(samples.last.detail['address'], '::1');
    expect(seen, ['127.0.0.1', '::1']);
  });

  test('a responding address is not replaced while it still answers', () async {
    final echo = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(echo.close);
    echo.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = echo.receive();
      if (datagram == null) {
        return;
      }
      echo.send(datagram.data, datagram.address, datagram.port);
    });
    final samples = await _collect(
      ProbeRequest(
        host: 'example.test',
        port: echo.port,
        profileId: 'udp-generic',
        interval: const Duration(milliseconds: 40),
        timeout: const Duration(milliseconds: 300),
        packetSize: 16,
        echoToken: '',
        dnsName: '',
        payloadHex: '',
        expectHex: '',
      ),
      count: 3,
      loop: ProbeLoop(
        lookup: (_) async => [
          InternetAddress('127.0.0.1'),
          InternetAddress('2001:db8::1'),
        ],
      ),
    );
    expect(samples.map((sample) => sample.status), everyElement(Outcome.ok));
    expect(samples.map((sample) => sample.detail['address']), everyElement('127.0.0.1'));
  });
}

Future<List<ProbeSample>> _collect(
  ProbeRequest request, {
  required int count,
  ProbeLoop? loop,
}) async {
  final probe = loop ?? ProbeLoop();
  final samples = <ProbeSample>[];
  var stop = false;
  await probe
      .run(
        request: request,
        onSample: (sample) {
          samples.add(sample);
          if (samples.length >= count) {
            stop = true;
          }
        },
        cancelled: () => stop,
      )
      .timeout(const Duration(seconds: 6));
  return samples;
}

Future<({Process process, int tcp, int udp})> _reflector() async {
  final tcp = await _freeTcp();
  final udp = await _freeUdp();
  final process = await Process.start(binary, [
    '-bind',
    '127.0.0.1',
    '-tcp-port',
    '$tcp',
    '-udp-port',
    '$udp',
    '-mode',
    'reflector',
  ]);
  await _waitListen(process);
  return (process: process, tcp: tcp, udp: udp);
}

Future<({Process process, int control, int udp, void Function() kill})> _node() async {
  final udp = await _freeUdp();
  final control = await _freeTcp();
  final process = await Process.start(binary, [
    '-bind',
    '127.0.0.1',
    '-tcp-port',
    '0',
    '-udp-port',
    '$udp',
    '-mode',
    'both',
    '-control-addr',
    '127.0.0.1:$control',
    '-allow-private',
  ]);
  final ready = Completer<void>();
  process.stderr.transform(utf8.decoder).listen((text) {
    if (text.contains('node control listening') && !ready.isCompleted) {
      ready.complete();
    }
  });
  process.stdout.transform(utf8.decoder).listen((_) {});
  await ready.future.timeout(const Duration(seconds: 3));
  return (
    process: process,
    control: control,
    udp: udp,
    kill: () {
      process.kill();
    },
  );
}

Future<void> _waitListen(Process process) async {
  final ready = Completer<void>();
  process.stderr.transform(utf8.decoder).listen((text) {
    if (text.contains('listening') && !ready.isCompleted) {
      ready.complete();
    }
  });
  process.stdout.transform(utf8.decoder).listen((_) {});
  await ready.future.timeout(const Duration(seconds: 3));
}

Future<int> _freeTcp() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<int> _freeUdp() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}

Future<({int port, Future<void> Function() close})> _javaServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((socket) async {
    final reader = _Reader(socket);
    await reader.next();
    await reader.next();
    const status =
        '{"version":{"name":"1.21.1","protocol":767},"players":{"online":3,"max":20},"description":{"text":"Hello"}}';
    final payload = BytesBuilder(copy: false)
      ..addByte(0x00)
      ..add(mcString(status));
    socket.add(mcPacket(payload.toBytes()));
    final ping = await reader.next();
    if (ping != null) {
      socket.add(mcPacket(ping));
    }
    await socket.close();
  });
  return (
    port: server.port,
    close: () async {
      await sub.cancel();
      await server.close();
    },
  );
}

Future<({int port, void Function() close})> _bedrockServer() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final datagram = socket.receive();
    if (datagram == null || datagram.data.length < 9) {
      return;
    }
    final ts = datagram.data.sublist(1, 9);
    const motd = 'MCPE;Bed;844;1.21.50;1;10;0;world;Survival;1;19132;0;';
    final body = BytesBuilder(copy: false)
      ..addByte(0x1c)
      ..add(ts)
      ..add(const [0, 0, 0, 0, 0, 0, 0, 99])
      ..add(rakMagic)
      ..addByte(0)
      ..addByte(motd.length)
      ..add(motd.codeUnits);
    socket.send(body.toBytes(), datagram.address, datagram.port);
  });
  return (
    port: socket.port,
    close: () {
      sub.cancel();
      socket.close();
    },
  );
}

class _Reader {
  _Reader(this.socket) {
    socket.listen((data) {
      _buf.add(data);
      _pending?.complete();
      _pending = null;
    });
  }

  final Socket socket;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Completer<void>? _pending;

  Future<Uint8List?> next() async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (true) {
      final bytes = _buf.toBytes();
      final packet = takeMcPacket(bytes);
      if (packet != null) {
        _buf.clear();
        if (packet.used < bytes.length) {
          _buf.add(Uint8List.sublistView(bytes, packet.used));
        }
        return packet.payload;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        return null;
      }
      final waiter = Completer<void>();
      _pending = waiter;
      if (takeMcPacket(_buf.toBytes()) != null) {
        waiter.complete();
      }
      try {
        await waiter.future.timeout(left);
      } on TimeoutException {
        return null;
      }
    }
  }
}
