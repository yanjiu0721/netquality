import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../metrics/sample_book.dart';
import '../protocol/probe_packet.dart';
import 'endpoint_picker.dart';
import 'game_codec.dart';

class ProbeRequest {
  const ProbeRequest({
    required this.host,
    required this.port,
    required this.profileId,
    required this.interval,
    required this.timeout,
    required this.packetSize,
    required this.echoToken,
    required this.dnsName,
    required this.payloadHex,
    required this.expectHex,
  });

  final String host;
  final int port;
  final String profileId;
  final Duration interval;
  final Duration timeout;
  final int packetSize;
  final String echoToken;
  final String dnsName;
  final String payloadHex;
  final String expectHex;
}

/// Sends one probe at a time from this device. A cancelled attempt is not
/// recorded, so stopping cannot paint a fake loss sample.
class ProbeLoop {
  ProbeLoop({
    this.lookup,
    this.onEndpoint,
  });

  /// Replaces [lookupAll] in tests.
  final Future<List<InternetAddress>> Function(String host)? lookup;

  /// Fires when the address about to be used is chosen or changed.
  final void Function(InternetAddress address)? onEndpoint;

  _TcpPipe? _tcp;
  _UdpPipe? _udp;
  EndpointPicker? _picker;
  InternetAddress? _announced;
  int _seq = 0;
  int _dnsId = 1;
  final int _guid = DateTime.now().microsecondsSinceEpoch;

  Future<void> run({
    required ProbeRequest request,
    required void Function(ProbeSample sample) onSample,
    required bool Function() cancelled,
  }) async {
    final book = SampleBook(request.profileId);
    try {
      while (!cancelled()) {
        final started = DateTime.now();
        final outcome = await _once(request, cancelled);
        if (cancelled() || outcome == null) {
          break;
        }
        if (_usesDatagram(request.profileId)) {
          final responded = outcome.status == Outcome.ok ||
              outcome.status == Outcome.protocol ||
              outcome.status == Outcome.refused;
          if (_picker != null && _picker!.record(responded)) {
            await _dropUdp();
            _announce(_picker!.current);
          }
        }
        book.add(outcome);
        onSample(book.sample(book.sent, outcome));
        final spent = DateTime.now().difference(started);
        final rest = request.interval - spent;
        if (!cancelled() && rest > Duration.zero) {
          await Future<void>.delayed(rest);
        }
      }
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    final tcp = _tcp;
    _tcp = null;
    if (tcp != null) {
      await tcp.close();
    }
    final udp = _udp;
    _udp = null;
    if (udp != null) {
      await udp.close();
    }
  }

  Future<Outcome?> _once(ProbeRequest request, bool Function() cancelled) async {
    try {
      final outcome = await _dispatch(request, cancelled);
      final peer = _udp?.peer;
      if (peer != null && _usesDatagram(request.profileId)) {
        return _stampAddress(outcome, peer);
      }
      return outcome;
    } on SocketException catch (error) {
      if (cancelled()) {
        return null;
      }
      return classifySocket(error);
    } on TimeoutException {
      if (cancelled()) {
        return null;
      }
      return const Outcome(
        status: Outcome.timeout,
        kind: Outcome.connect,
        note: '连接超时',
      );
    }
  }

  Future<Outcome> _dispatch(ProbeRequest request, bool Function() cancelled) {
    switch (request.profileId) {
      case 'nq-tcp':
        return _nqTcp(request, cancelled);
      case 'nq-udp':
        return _nqUdp(request, cancelled);
      case 'tcp-connect':
        return _tcpConnect(request, cancelled);
      case 'udp-generic':
      case 'custom-udp':
        return _udpQuery(request, cancelled);
      case 'dns':
        return _dns(request, cancelled);
      case 'minecraft-java':
        return _java(request, cancelled);
      case 'minecraft-bedrock':
        return _bedrock(request, cancelled);
      default:
        return Future.value(
          const Outcome(
            status: Outcome.error,
            kind: Outcome.query,
            note: '不支持的探测类型',
          ),
        );
    }
  }

  Future<Outcome> _tcpConnect(
    ProbeRequest request,
    bool Function() cancelled,
  ) async {
    final watch = Stopwatch()..start();
    final socket = await Socket.connect(
      request.host,
      request.port,
      timeout: request.timeout,
    );
    watch.stop();
    await socket.close();
    if (cancelled()) {
      return const Outcome(status: Outcome.timeout, kind: Outcome.connect, note: '已停止');
    }
    return Outcome(
      status: Outcome.ok,
      kind: Outcome.connect,
      rttMs: watch.elapsedMicroseconds / 1000,
      note: 'TCP 已连通',
    );
  }

  Future<Outcome> _nqTcp(ProbeRequest request, bool Function() cancelled) async {
    if (_tcp == null) {
      try {
        final socket = await Socket.connect(
          request.host,
          request.port,
          timeout: request.timeout,
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        _tcp = _TcpPipe(socket);
      } on SocketException catch (error) {
        return classifySocket(error, reconnect: true);
      } on TimeoutException {
        return const Outcome(
          status: Outcome.timeout,
          kind: Outcome.connect,
          reconnect: true,
          note: '连接超时，将重试',
        );
      }
    }
    final pipe = _tcp!;
    _seq += 1;
    final seq = _seq;
    final packet = ProbePacket(
      type: ProbePacket.typeRequest,
      sequence: seq,
      clientSendUnixNano: DateTime.now().microsecondsSinceEpoch * 1000,
      token: ProbePacket.encodeToken(request.echoToken),
      payload: Uint8List(request.packetSize - ProbePacket.headerSize),
    );
    pipe.socket.add(packet.encode());
    try {
      await pipe.socket.flush();
    } on SocketException {
      await _dropTcp();
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.connect,
        reconnect: true,
        note: '发送失败，连接将重连',
      );
    }
    final watch = Stopwatch()..start();
    final matched = await pipe.waitMatch(request.timeout, (frame) {
      try {
        final reply = ProbePacket.decode(frame);
        return reply.isReply && reply.sequence == seq;
      } on ProbePacketException {
        return false;
      }
    });
    if (cancelled()) {
      return const Outcome(status: Outcome.timeout, kind: Outcome.connect, note: '已停止');
    }
    if (matched == null) {
      await _dropTcp();
      return const Outcome(
        status: Outcome.timeout,
        kind: Outcome.probe,
        note: '已发出探测，超时前没有收到回显。TCP 会重传，这不是已证实的物理丢包',
      );
    }
    return Outcome(
      status: Outcome.ok,
      kind: Outcome.probe,
      rttMs: watch.elapsedMicroseconds / 1000,
      note: '收到回显',
    );
  }

  Future<void> _dropTcp() async {
    final tcp = _tcp;
    _tcp = null;
    if (tcp != null) {
      await tcp.close();
    }
  }

  Future<Outcome> _nqUdp(ProbeRequest request, bool Function() cancelled) async {
    final pipe = await _datagram(request);
    _seq += 1;
    final seq = _seq;
    final packet = ProbePacket(
      type: ProbePacket.typeRequest,
      sequence: seq,
      clientSendUnixNano: DateTime.now().microsecondsSinceEpoch * 1000,
      token: ProbePacket.encodeToken(request.echoToken),
      payload: Uint8List(request.packetSize - ProbePacket.headerSize),
    );
    final watch = Stopwatch()..start();
    pipe.send(packet.encode(), request.port);
    var sawInvalid = false;
    final reply = await pipe.waitMatch(request.timeout, (data) {
      try {
        final parsed = ProbePacket.decode(data);
        if (!parsed.isReply) {
          sawInvalid = true;
          return false;
        }
        return parsed.sequence == seq;
      } on ProbePacketException {
        sawInvalid = true;
        return false;
      }
    });
    if (cancelled()) {
      return const Outcome(status: Outcome.unknown, kind: Outcome.query, note: '已停止');
    }
    if (reply == null) {
      if (sawInvalid) {
        return const Outcome(
          status: Outcome.protocol,
          kind: Outcome.probe,
          note: '收到的 UDP 包不是有效回显',
        );
      }
      return const Outcome(
        status: Outcome.timeout,
        kind: Outcome.probe,
        note: '未收到回显。这是探测没有应答，不是网卡上的物理丢包计数',
      );
    }
    return Outcome(
      status: Outcome.ok,
      kind: Outcome.probe,
      rttMs: watch.elapsedMicroseconds / 1000,
      note: '收到回显',
    );
  }

  Future<Outcome> _udpQuery(
    ProbeRequest request,
    bool Function() cancelled,
  ) async {
    final pipe = await _datagram(request);
    late final Uint8List payload;
    Uint8List? expect;
    if (request.profileId == 'udp-generic') {
      payload = Uint8List(request.packetSize.clamp(1, 1400));
    } else {
      payload = decodeHex(request.payloadHex);
      if (request.expectHex.trim().isNotEmpty) {
        expect = decodeHex(request.expectHex);
      }
    }
    final watch = Stopwatch()..start();
    pipe.send(payload, request.port);
    final reply = await pipe.waitMatch(request.timeout, (_) => true);
    if (cancelled()) {
      return const Outcome(status: Outcome.unknown, kind: Outcome.query, note: '已停止');
    }
    if (reply == null) {
      return const Outcome(
        status: Outcome.unknown,
        kind: Outcome.query,
        note: '没有收到 UDP 应答，不能据此断定物理丢包',
      );
    }
    final wanted = expect;
    if (wanted != null && (reply.length < wanted.length || !_prefix(reply, wanted))) {
      return const Outcome(
        status: Outcome.protocol,
        kind: Outcome.query,
        note: '收到了数据，但和预期的响应不一致',
      );
    }
    return Outcome(
      status: Outcome.ok,
      kind: Outcome.query,
      rttMs: watch.elapsedMicroseconds / 1000,
      note: '收到 UDP 响应',
    );
  }

  Future<Outcome> _dns(ProbeRequest request, bool Function() cancelled) async {
    final pipe = await _datagram(request);
    _dnsId = _dnsId == 65535 ? 1 : _dnsId + 1;
    final id = _dnsId;
    final name = request.dnsName.trim().isEmpty ? 'example.com' : request.dnsName.trim();
    final watch = Stopwatch()..start();
    pipe.send(dnsQuery(id, name), request.port);
    var malformed = false;
    final reply = await pipe.waitMatch(request.timeout, (data) {
      if (data.length < 12) {
        malformed = true;
        return false;
      }
      final got = ByteData.sublistView(data).getUint16(0);
      if (got != id) {
        return false;
      }
      if ((data[2] & 0x80) == 0) {
        malformed = true;
        return false;
      }
      return true;
    });
    if (cancelled()) {
      return const Outcome(status: Outcome.unknown, kind: Outcome.query, note: '已停止');
    }
    if (reply == null) {
      if (malformed) {
        return const Outcome(
          status: Outcome.protocol,
          kind: Outcome.query,
          note: '收到的包不是 DNS 应答',
        );
      }
      return const Outcome(
        status: Outcome.unknown,
        kind: Outcome.query,
        note: '没有收到 DNS 应答，不能据此断定物理丢包',
      );
    }
    return Outcome(
      status: Outcome.ok,
      kind: Outcome.query,
      rttMs: watch.elapsedMicroseconds / 1000,
      note: '收到 DNS 应答',
    );
  }

  Future<Outcome> _bedrock(
    ProbeRequest request,
    bool Function() cancelled,
  ) async {
    final pipe = await _datagram(request);
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final watch = Stopwatch()..start();
    pipe.send(bedrockPing(timestamp, _guid), request.port);
    Map<String, String>? detail;
    var sawInvalid = false;
    final reply = await pipe.waitMatch(request.timeout, (data) {
      final parsed = parseRakPong(data, timestamp);
      if (parsed == null) {
        sawInvalid = true;
        return false;
      }
      detail = parsed;
      return true;
    });
    if (cancelled()) {
      return const Outcome(status: Outcome.unknown, kind: Outcome.query, note: '已停止');
    }
    if (reply == null) {
      if (sawInvalid) {
        return const Outcome(
          status: Outcome.protocol,
          kind: Outcome.query,
          note: '收到的包不是有效的 RakNet Pong',
        );
      }
      return const Outcome(
        status: Outcome.unknown,
        kind: Outcome.query,
        note: '未收到 RakNet 应答，不能据此断定物理丢包',
      );
    }
    return Outcome(
      status: Outcome.ok,
      kind: Outcome.query,
      rttMs: watch.elapsedMicroseconds / 1000,
      note: '收到 Bedrock 应答',
      detail: detail ?? const {},
    );
  }

  Future<Outcome> _java(ProbeRequest request, bool Function() cancelled) async {
    final socket = await Socket.connect(
      request.host,
      request.port,
      timeout: request.timeout,
    );
    final reader = _BytePipe(socket);
    try {
      socket.add(javaHandshake(request.host, request.port));
      socket.add(javaStatusRequest());
      await socket.flush();
      final status = await reader.nextPacket(request.timeout);
      if (status == null || status.isEmpty || status[0] != 0x00) {
        return const Outcome(
          status: Outcome.protocol,
          kind: Outcome.query,
          note: 'Minecraft 状态响应无效',
        );
      }
      final jsonText = readMcString(status, 1);
      if (jsonText == null) {
        return const Outcome(
          status: Outcome.protocol,
          kind: Outcome.query,
          note: 'Minecraft 状态内容无法解析',
        );
      }
      final detail = minecraftStatusDetail(jsonText);
      final nonce = DateTime.now().microsecondsSinceEpoch;
      final watch = Stopwatch()..start();
      socket.add(javaPing(nonce));
      await socket.flush();
      final pong = await reader.nextPacket(request.timeout);
      if (cancelled()) {
        return const Outcome(status: Outcome.timeout, kind: Outcome.connect, note: '已停止');
      }
      if (pong == null || pong.length != 9 || pong[0] != 0x01) {
        return Outcome(
          status: Outcome.protocol,
          kind: Outcome.query,
          note: '没有收到有效的 Minecraft pong',
          detail: detail,
        );
      }
      if (ByteData.sublistView(pong).getUint64(1) != nonce) {
        return Outcome(
          status: Outcome.protocol,
          kind: Outcome.query,
          note: 'Minecraft pong 的时间戳不匹配',
          detail: detail,
        );
      }
      return Outcome(
        status: Outcome.ok,
        kind: Outcome.query,
        rttMs: watch.elapsedMicroseconds / 1000,
        note: '收到 Minecraft 状态和 ping 应答',
        detail: detail,
      );
    } finally {
      await reader.close();
      await socket.close();
    }
  }

  Future<_UdpPipe> _datagram(ProbeRequest request) async {
    _picker ??= EndpointPicker(await (lookup ?? lookupAll)(request.host));
    final want = _picker!.current;
    final existing = _udp;
    if (existing != null && existing.peer.address == want.address) {
      return existing;
    }
    if (existing != null) {
      await existing.close();
      _udp = null;
    }
    final socket = await RawDatagramSocket.bind(
      want.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    final pipe = _UdpPipe(socket, want);
    _udp = pipe;
    _announce(want);
    return pipe;
  }

  void _announce(InternetAddress address) {
    if (_announced != null && _announced!.address == address.address) {
      return;
    }
    _announced = address;
    onEndpoint?.call(address);
  }

  Future<void> _dropUdp() async {
    final udp = _udp;
    _udp = null;
    if (udp != null) {
      await udp.close();
    }
  }
}

bool _usesDatagram(String profileId) {
  switch (profileId) {
    case 'nq-udp':
    case 'udp-generic':
    case 'custom-udp':
    case 'dns':
    case 'minecraft-bedrock':
      return true;
    default:
      return false;
  }
}

Outcome _stampAddress(Outcome outcome, InternetAddress peer) {
  return Outcome(
    status: outcome.status,
    kind: outcome.kind,
    rttMs: outcome.rttMs,
    note: outcome.note,
    reconnect: outcome.reconnect,
    detail: {...outcome.detail, 'address': peer.address},
  );
}

Outcome classifySocket(SocketException error, {bool reconnect = false}) {
  final text = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  final code = error.osError?.errorCode;
  if (text.contains('timed out') || text.contains('timeout')) {
    return Outcome(
      status: Outcome.timeout,
      kind: Outcome.connect,
      reconnect: reconnect,
      note: reconnect ? '连接超时，将重试' : '连接超时',
    );
  }
  if (text.contains('failed host lookup') ||
      text.contains('name or service not known') ||
      text.contains('nodename nor servname') ||
      text.contains('no address associated')) {
    return const Outcome(
      status: Outcome.dns,
      kind: Outcome.connect,
      note: '域名无法解析',
    );
  }
  if (code == 111 ||
      code == 61 ||
      code == 10061 ||
      text.contains('connection refused') ||
      text.contains('actively refused')) {
    return Outcome(
      status: Outcome.refused,
      kind: Outcome.connect,
      reconnect: reconnect,
      note: '连接被拒绝',
    );
  }
  return Outcome(
    status: Outcome.error,
    kind: Outcome.connect,
    reconnect: reconnect,
    note: '连接失败',
  );
}

bool _prefix(Uint8List data, Uint8List prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

class _TcpPipe {
  _TcpPipe(this.socket) {
    _sub = socket.listen(
      (data) {
        try {
          _frames.addAll(_buffer.add(data));
        } on ProbePacketException {
          _failed = true;
        }
        _signal();
      },
      onError: (Object _) {
        _failed = true;
        _signal();
      },
      onDone: () {
        _failed = true;
        _signal();
      },
      cancelOnError: true,
    );
  }

  final Socket socket;
  final FrameBuffer _buffer = FrameBuffer();
  final List<Uint8List> _frames = [];
  late final StreamSubscription<Uint8List> _sub;
  Completer<void>? _pending;
  bool _failed = false;
  var _cursor = 0;

  void _signal() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  Future<Uint8List?> waitMatch(
    Duration timeout,
    bool Function(Uint8List frame) match,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_cursor < _frames.length) {
        final frame = _frames[_cursor];
        _cursor += 1;
        if (match(frame)) {
          return frame;
        }
      }
      if (_failed) {
        return null;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        return null;
      }
      final waiter = Completer<void>();
      _pending = waiter;
      if (_cursor < _frames.length || _failed) {
        _signal();
      }
      try {
        await waiter.future.timeout(left);
      } on TimeoutException {
        if (identical(_pending, waiter)) {
          _pending = null;
        }
        return null;
      }
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
    _signal();
  }
}

class _UdpPipe {
  _UdpPipe(this.socket, this.peer) {
    _sub = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      while (true) {
        final datagram = socket.receive();
        if (datagram == null) {
          return;
        }
        _queue.add(Uint8List.fromList(datagram.data));
        _signal();
      }
    });
  }

  final RawDatagramSocket socket;
  final InternetAddress peer;
  final List<Uint8List> _queue = [];
  late final StreamSubscription<RawSocketEvent> _sub;
  Completer<void>? _pending;
  var _cursor = 0;

  void send(List<int> bytes, int port) {
    socket.send(bytes, peer, port);
  }

  void _signal() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  Future<Uint8List?> waitMatch(
    Duration timeout,
    bool Function(Uint8List data) match,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_cursor < _queue.length) {
        final data = _queue[_cursor];
        _cursor += 1;
        if (match(data)) {
          return data;
        }
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        return null;
      }
      final waiter = Completer<void>();
      _pending = waiter;
      if (_cursor < _queue.length) {
        _signal();
      }
      try {
        await waiter.future.timeout(left);
      } on TimeoutException {
        if (identical(_pending, waiter)) {
          _pending = null;
        }
        return null;
      }
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    socket.close();
    _signal();
  }
}

class _BytePipe {
  _BytePipe(this.socket) {
    _sub = socket.listen((data) {
      _buf.add(data);
      _signal();
    });
  }

  final Socket socket;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> _sub;
  Completer<void>? _pending;

  void _signal() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  Future<Uint8List?> nextPacket(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
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
        _signal();
      }
      try {
        await waiter.future.timeout(left);
      } on TimeoutException {
        if (identical(_pending, waiter)) {
          _pending = null;
        }
        return null;
      }
    }
  }

  Future<void> close() => _sub.cancel();
}
