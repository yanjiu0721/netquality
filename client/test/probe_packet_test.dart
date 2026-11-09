import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/protocol/probe_packet.dart';

void main() {
  test('golden request matches the server fixture', () {
    final packet = ProbePacket(
      type: ProbePacket.typeRequest,
      sequence: 1,
      clientSendUnixNano: 1000,
      payload: Uint8List.fromList([1, 2, 3, 4]),
    );
    final hex = packet
        .encode()
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(
      hex,
      '4e5130310101000001000000e803000000000000'
      '0000000000000000000000000000000000000000'
      '0000000000000000000000000000000000000000'
      '040001020304',
    );
    final back = ProbePacket.decode(packet.encode());
    expect(back.sequence, 1);
    expect(back.clientSendUnixNano, 1000);
    expect(back.type, ProbePacket.typeRequest);
    expect(back.payload, [1, 2, 3, 4]);
  });

  test('token is zero padded in the header', () {
    final token = ProbePacket.encodeToken('demo');
    expect(token, hasLength(32));
    expect(token.sublist(0, 4), [0x64, 0x65, 0x6d, 0x6f]);
    expect(token.sublist(4), everyElement(0));
    expect(() => ProbePacket.encodeToken('x' * 33), throwsA(isA<ProbePacketException>()));
  });

  test('frame buffer splits partial and concatenated TCP frames', () {
    final packet = ProbePacket(
      type: ProbePacket.typeReply,
      sequence: 9,
      clientSendUnixNano: 50,
      serverUnixNano: 80,
      payload: Uint8List.fromList([9, 8, 7]),
    ).encode();
    final buffer = FrameBuffer();
    expect(buffer.add(packet.sublist(0, 20)), isEmpty);
    expect(buffer.add(packet.sublist(20, 40)), isEmpty);
    final one = buffer.add(packet.sublist(40));
    expect(one, hasLength(1));
    expect(ProbePacket.decode(one.single).sequence, 9);
    expect(ProbePacket.decode(one.single).serverUnixNano, 80);

    final both = Uint8List.fromList([...packet, ...packet]);
    final two = FrameBuffer().add(both);
    expect(two, hasLength(2));
    expect(ProbePacket.decode(two[1]).payload, [9, 8, 7]);
  });

  test('rejects a short or trailing datagram', () {
    final packet = ProbePacket(
      type: ProbePacket.typeRequest,
      sequence: 1,
      clientSendUnixNano: 1,
    ).encode();
    expect(
      () => ProbePacket.decode(Uint8List.sublistView(packet, 0, 10)),
      throwsA(isA<ProbePacketException>()),
    );
    final extra = Uint8List(packet.length + 1)..setRange(0, packet.length, packet);
    expect(() => ProbePacket.decode(extra), throwsA(isA<ProbePacketException>()));
  });
}
