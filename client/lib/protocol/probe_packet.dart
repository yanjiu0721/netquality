import 'dart:convert';
import 'dart:typed_data';

/// Wire format shared by TCP frames and UDP datagrams.
///
/// See docs/PROTOCOL.md. Header is 62 bytes, little-endian.
/// A TCP stream is a sequence of these frames. A UDP datagram is exactly one.
class ProbePacket {
  ProbePacket({
    required this.type,
    required this.sequence,
    required this.clientSendUnixNano,
    this.serverUnixNano = 0,
    Uint8List? token,
    Uint8List? payload,
    this.version = version1,
  }) : token = token ?? Uint8List(tokenLength),
       payload = payload ?? Uint8List(0);

  static const version1 = 1;
  static const headerSize = 62;
  static const tokenLength = 32;
  static const tokenOffset = 28;
  static const maxPayload = 2048;
  static const typeRequest = 1;
  static const typeReply = 2;

  static const magic0 = 0x4e; // N
  static const magic1 = 0x51; // Q
  static const magic2 = 0x30; // 0
  static const magic3 = 0x31; // 1

  final int version;
  final int type;
  final int sequence;
  final int clientSendUnixNano;
  final int serverUnixNano;
  final Uint8List token;
  final Uint8List payload;

  bool get isReply => type == typeReply;

  Uint8List encode() {
    if (token.length != tokenLength) {
      throw ProbePacketException('token must be $tokenLength bytes');
    }
    if (payload.length > maxPayload) {
      throw ProbePacketException('payload too large');
    }
    final out = Uint8List(headerSize + payload.length);
    final data = ByteData.sublistView(out);
    out[0] = magic0;
    out[1] = magic1;
    out[2] = magic2;
    out[3] = magic3;
    data.setUint8(4, version);
    data.setUint8(5, type);
    data.setUint8(6, 0);
    data.setUint8(7, 0);
    data.setUint32(8, sequence, Endian.little);
    data.setUint64(12, clientSendUnixNano, Endian.little);
    data.setUint64(20, serverUnixNano, Endian.little);
    out.setRange(tokenOffset, tokenOffset + tokenLength, token);
    data.setUint16(60, payload.length, Endian.little);
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  static ProbePacket decode(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw ProbePacketException('packet shorter than header');
    }
    if (bytes[0] != magic0 ||
        bytes[1] != magic1 ||
        bytes[2] != magic2 ||
        bytes[3] != magic3) {
      throw ProbePacketException('bad magic');
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint8(4);
    if (version != version1) {
      throw ProbePacketException('unsupported version $version');
    }
    final type = data.getUint8(5);
    if (type != typeRequest && type != typeReply) {
      throw ProbePacketException('unsupported type $type');
    }
    final payloadLen = data.getUint16(60, Endian.little);
    if (payloadLen > maxPayload) {
      throw ProbePacketException('payload too large');
    }
    final total = headerSize + payloadLen;
    if (bytes.length != total) {
      throw ProbePacketException(
        'length mismatch: have ${bytes.length}, want $total',
      );
    }
    return ProbePacket(
      version: version,
      type: type,
      sequence: data.getUint32(8, Endian.little),
      clientSendUnixNano: data.getUint64(12, Endian.little),
      serverUnixNano: data.getUint64(20, Endian.little),
      token: Uint8List.sublistView(bytes, tokenOffset, tokenOffset + tokenLength),
      payload: payloadLen == 0
          ? Uint8List(0)
          : Uint8List.sublistView(bytes, headerSize, total),
    );
  }

  /// UTF-8 token padded with zeros. Empty string is 32 zero bytes.
  static Uint8List encodeToken(String token) {
    final raw = utf8.encode(token);
    if (raw.length > tokenLength) {
      throw ProbePacketException('口令最长 $tokenLength 字节');
    }
    final out = Uint8List(tokenLength);
    out.setRange(0, raw.length, raw);
    return out;
  }
}

class ProbePacketException implements Exception {
  ProbePacketException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reassembles TCP frames. UDP datagrams are already one frame and do not
/// need this buffer.
class FrameBuffer {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  List<Uint8List> add(List<int> chunk) {
    _buf.add(chunk);
    final bytes = _buf.toBytes();
    var offset = 0;
    final frames = <Uint8List>[];
    while (bytes.length - offset >= ProbePacket.headerSize) {
      final view = ByteData.sublistView(bytes, offset);
      final payloadLen = view.getUint16(60, Endian.little);
      if (payloadLen > ProbePacket.maxPayload) {
        _buf.clear();
        throw ProbePacketException('payload too large');
      }
      final total = ProbePacket.headerSize + payloadLen;
      if (bytes.length - offset < total) {
        break;
      }
      frames.add(Uint8List.sublistView(bytes, offset, offset + total));
      offset += total;
    }
    _buf.clear();
    if (offset < bytes.length) {
      _buf.add(Uint8List.sublistView(bytes, offset));
    }
    return frames;
  }

  void clear() {
    _buf.clear();
  }
}
