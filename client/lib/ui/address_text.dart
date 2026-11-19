// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

class ResolvedAddress {
  const ResolvedAddress({required this.address, required this.family});

  final String address;
  final String family;
}

String addressFamily(InternetAddress address) {
  return address.type == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';
}

String familyOfAddress(String address) {
  final parsed = InternetAddress.tryParse(address);
  if (parsed == null) {
    return '';
  }
  return addressFamily(parsed);
}

class AddressLines {
  const AddressLines({
    this.used,
    this.trying,
    this.resolved,
    this.fallback,
    this.unreported,
    this.fake = false,
  });

  final String? used;
  final String? trying;
  final String? resolved;
  final String? fallback;
  final String? unreported;
  final bool fake;
}

/// [used] is an address a probe actually connected to or sent to.
/// [resolved] is only the lookup result and is never labeled as the address
/// in use. A remote sample that omits the address stays unreported.
AddressLines describeAddress({
  required List<ResolvedAddress> resolved,
  String? usedAddress,
  String? usedFamily,
  String? tryingAddress,
  String? tryingFamily,
  String fallbackText = '',
  bool addressUnreported = false,
  bool usedIsFake = false,
}) {
  final hasUsed = usedAddress != null && usedAddress.isNotEmpty;
  String? used;
  if (hasUsed) {
    final family = (usedFamily == null || usedFamily.isEmpty)
        ? familyOfAddress(usedAddress)
        : usedFamily;
    used = family.isEmpty ? '实际地址 $usedAddress' : '实际地址 $usedAddress（$family）';
  }
  String? trying;
  if (!hasUsed && tryingAddress != null && tryingAddress.isNotEmpty) {
    final family = (tryingFamily == null || tryingFamily.isEmpty)
        ? ''
        : '（$tryingFamily）';
    trying = '正在尝试 $tryingAddress$family，还没有正式结果';
  }
  String? resolvedLine;
  if (resolved.isNotEmpty) {
    final sameSingle =
        resolved.length == 1 &&
        hasUsed &&
        resolved.single.address == usedAddress;
    if (!sameSingle) {
      final text = resolved
          .map((item) {
            final family = item.family.isEmpty ? '' : '（${item.family}）';
            return '${item.address}$family';
          })
          .join('、');
      resolvedLine = '解析到 $text';
    }
  }
  return AddressLines(
    used: used,
    trying: trying,
    resolved: resolvedLine,
    fallback: fallbackText.isEmpty ? null : fallbackText,
    unreported: addressUnreported && !hasUsed ? '节点没有报告实际使用的地址' : null,
    fake: usedIsFake && hasUsed,
  );
}

List<ResolvedAddress> readResolvedList(Object? parsed) {
  if (parsed is! Map) {
    return const [];
  }
  final raw = parsed['resolved'];
  if (raw is! List) {
    return const [];
  }
  final out = <ResolvedAddress>[];
  for (final item in raw) {
    if (item is! Map) {
      continue;
    }
    final address = item['address'];
    if (address is! String || address.isEmpty) {
      continue;
    }
    final family = item['family'];
    out.add(
      ResolvedAddress(
        address: address,
        family: family is String && family.isNotEmpty
            ? family
            : familyOfAddress(address),
      ),
    );
  }
  return out;
}
