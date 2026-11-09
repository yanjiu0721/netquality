import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/probe/endpoint_picker.dart';

void main() {
  test('a miss before any answer tries the next address', () {
    final v6 = InternetAddress('2001:db8::1');
    final v4 = InternetAddress('203.0.113.5');
    final picker = EndpointPicker([v6, v4]);
    expect(picker.current, v6);
    expect(picker.record(false), isTrue);
    expect(picker.current, v4);
    expect(picker.record(true), isFalse);
    expect(picker.current, v4);
    expect(picker.hasAnswered, isTrue);
  });

  test('a working address survives two misses and leaves on the third', () {
    final v4 = InternetAddress('203.0.113.5');
    final v6 = InternetAddress('2001:db8::1');
    final picker = EndpointPicker([v4, v6]);
    expect(picker.record(true), isFalse);
    expect(picker.record(false), isFalse);
    expect(picker.record(false), isFalse);
    expect(picker.current, v4);
    expect(picker.record(false), isTrue);
    expect(picker.current, v6);
    expect(picker.hasAnswered, isFalse);
    expect(picker.record(false), isTrue);
    expect(picker.current, v4);
  });

  test('one address is never abandoned', () {
    final only = InternetAddress('203.0.113.9');
    final picker = EndpointPicker([only]);
    expect(picker.record(false), isFalse);
    expect(picker.record(false), isFalse);
    expect(picker.current, only);
  });

  test('198.18.0.0/15 is treated as a VPN fake address', () {
    expect(isClashFakeIp(InternetAddress('198.18.0.1')), isTrue);
    expect(isClashFakeIp(InternetAddress('198.19.255.254')), isTrue);
    expect(isClashFakeIp(InternetAddress('198.17.255.255')), isFalse);
    expect(isClashFakeIp(InternetAddress('198.20.0.1')), isFalse);
    expect(isClashFakeIp(InternetAddress('180.172.93.226')), isFalse);
    expect(isClashFakeIp(InternetAddress('2001:db8::1')), isFalse);
  });
}
