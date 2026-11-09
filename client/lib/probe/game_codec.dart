import 'dart:convert';
import 'dart:typed_data';

const rakMagic = <int>[
  0x00,
  0xff,
  0xff,
  0x00,
  0xfe,
  0xfe,
  0xfe,
  0xfe,
  0xfd,
  0xfd,
  0xfd,
  0xfd,
  0x12,
  0x34,
  0x56,
  0x78,
];

Uint8List encodeVarInt(int value) {
  final out = <int>[];
  var u = value;
  while (true) {
    if ((u & ~0x7f) == 0) {
      out.add(u);
      return Uint8List.fromList(out);
    }
    out.add((u & 0x7f) | 0x80);
    u >>= 7;
  }
}

int? decodeVarInt(Uint8List bytes, int offset, void Function(int next) onNext) {
  var n = 0;
  for (var i = 0; i < 5; i++) {
    if (offset + i >= bytes.length) {
      return null;
    }
    final by = bytes[offset + i];
    n |= (by & 0x7f) << (7 * i);
    if ((by & 0x80) == 0) {
      onNext(offset + i + 1);
      return n;
    }
  }
  throw const FormatException('varint');
}

Uint8List mcString(String value) {
  final raw = utf8.encode(value);
  final out = BytesBuilder(copy: false);
  out.add(encodeVarInt(raw.length));
  out.add(raw);
  return out.toBytes();
}

Uint8List mcPacket(List<int> payload) {
  final out = BytesBuilder(copy: false);
  out.add(encodeVarInt(payload.length));
  out.add(payload);
  return out.toBytes();
}

/// Handshake for status state. Protocol 767 is Minecraft 1.21.x.
Uint8List javaHandshake(String host, int port) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(0x00);
  payload.add(encodeVarInt(767));
  payload.add(mcString(host));
  final data = ByteData(2)..setUint16(0, port);
  payload.add(data.buffer.asUint8List());
  payload.add(encodeVarInt(1));
  return mcPacket(payload.toBytes());
}

Uint8List javaStatusRequest() => mcPacket(const [0x00]);

Uint8List javaPing(int nonce) {
  final data = ByteData(9);
  data.setUint8(0, 0x01);
  data.setUint64(1, nonce);
  return mcPacket(data.buffer.asUint8List());
}

/// Returns the payload of one length-prefixed packet, and how many bytes it used.
({Uint8List payload, int used})? takeMcPacket(Uint8List bytes) {
  var offset = 0;
  final length = decodeVarInt(bytes, 0, (next) => offset = next);
  if (length == null || length < 1 || length > 1 << 20) {
    return null;
  }
  if (bytes.length < offset + length) {
    return null;
  }
  return (
    payload: Uint8List.sublistView(bytes, offset, offset + length),
    used: offset + length,
  );
}

Map<String, String> minecraftStatusDetail(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    return const {};
  }
  final out = <String, String>{};
  final version = decoded['version'];
  if (version is Map && version['name'] is String) {
    out['version'] = version['name'] as String;
  }
  final players = decoded['players'];
  if (players is Map) {
    final online = players['online'];
    final max = players['max'];
    if (online is num && max is num) {
      out['players'] = '${online.toInt()}/${max.toInt()}';
    }
  }
  final description = decoded['description'];
  final text = motdText(description);
  if (text.isNotEmpty) {
    out['motd'] = text;
  }
  return out;
}

String motdText(Object? value) {
  if (value is String) {
    return value;
  }
  if (value is Map) {
    final buf = StringBuffer();
    if (value['text'] is String) {
      buf.write(value['text']);
    }
    final extra = value['extra'];
    if (extra is List) {
      for (final item in extra) {
        buf.write(motdText(item));
      }
    }
    return buf.toString();
  }
  return '';
}

String? readMcString(Uint8List payload, int offset) {
  var next = offset;
  final length = decodeVarInt(payload, offset, (value) => next = value);
  if (length == null || length < 0 || next + length > payload.length) {
    return null;
  }
  return utf8.decode(payload.sublist(next, next + length), allowMalformed: true);
}

Uint8List bedrockPing(int timestamp, int guid) {
  final data = ByteData(1 + 8 + 16 + 8);
  data.setUint8(0, 0x01);
  data.setUint64(1, timestamp);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(9, 25, rakMagic);
  data.setUint64(25, guid);
  return bytes;
}

Map<String, String>? parseRakPong(Uint8List packet, int timestamp) {
  if (packet.length < 35 || packet[0] != 0x1c) {
    return null;
  }
  final data = ByteData.sublistView(packet);
  if (data.getUint64(1) != timestamp) {
    return null;
  }
  for (var i = 0; i < rakMagic.length; i++) {
    if (packet[17 + i] != rakMagic[i]) {
      return null;
    }
  }
  final strlen = data.getUint16(33);
  if (35 + strlen > packet.length) {
    return null;
  }
  final text = utf8.decode(packet.sublist(35, 35 + strlen), allowMalformed: true);
  final parts = text.split(';');
  final detail = <String, String>{};
  if (parts.length > 1) {
    detail['motd'] = parts[1];
  }
  if (parts.length > 3) {
    detail['version'] = parts[3];
  }
  if (parts.length > 5) {
    detail['players'] = '${parts[4]}/${parts[5]}';
  }
  return detail;
}

Uint8List dnsQuery(int id, String name) {
  final body = BytesBuilder(copy: false);
  for (final label in name.split('.')) {
    if (label.isEmpty) {
      continue;
    }
    final raw = utf8.encode(label);
    if (raw.length > 63) {
      throw const FormatException('label');
    }
    body.addByte(raw.length);
    body.add(raw);
  }
  body.add(const [0, 0, 1, 0, 1]);
  final question = body.toBytes();
  final msg = Uint8List(12 + question.length);
  final data = ByteData.sublistView(msg);
  data.setUint16(0, id);
  data.setUint16(2, 0x0100);
  data.setUint16(4, 1);
  msg.setRange(12, msg.length, question);
  return msg;
}

bool dnsResponseMatches(Uint8List packet, int id) {
  if (packet.length < 12) {
    return false;
  }
  final data = ByteData.sublistView(packet);
  return data.getUint16(0) == id && (packet[2] & 0x80) != 0;
}

Uint8List decodeHex(String raw) {
  final text = raw.replaceAll(RegExp(r'\s'), '');
  if (text.isEmpty || text.length.isOdd) {
    throw const FormatException('hex');
  }
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
