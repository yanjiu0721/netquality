// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

/// Host used for an address-family check. HTTP targets may be a full URL.
String probeHost(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return '';
  }
  if (text.contains('://')) {
    return Uri.tryParse(text)?.host ?? '';
  }
  final slash = text.indexOf('/');
  final host = slash >= 0 ? text.substring(0, slash) : text;
  return host.replaceAll('[', '').replaceAll(']', '');
}

/// Returns a message when the probe must not start. Null means the families allow it.
String? familyRefusal(
  String raw, {
  required bool v4,
  required bool v6,
}) {
  if (!v4 && !v6) {
    return 'IPv4 和 IPv6 都已关闭，无法开始探测。请在设置里至少打开一个。';
  }
  final host = probeHost(raw);
  final parsed = InternetAddress.tryParse(host);
  if (parsed == null) {
    return null;
  }
  if (parsed.type == InternetAddressType.IPv4 && !v4) {
    return '目标是 IPv4 地址，但设置里的 IPv4 已关闭。';
  }
  if (parsed.type == InternetAddressType.IPv6 && !v6) {
    return '目标是 IPv6 地址，但设置里的 IPv6 已关闭。';
  }
  return null;
}

List<InternetAddress> filterAddresses(
  List<InternetAddress> addresses, {
  required bool v4,
  required bool v6,
}) {
  return [
    for (final address in addresses)
      if ((address.type == InternetAddressType.IPv4 && v4) ||
          (address.type == InternetAddressType.IPv6 && v6))
        address,
  ];
}
