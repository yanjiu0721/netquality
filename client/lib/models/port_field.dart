// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'probe_profile.dart';

/// Keeps a port the user typed. An empty field or a value that is still the
/// previous profile's default follows the newly selected profile.
String portAfterProfileChange({
  required String current,
  required int previousDefault,
  required int nextDefault,
}) {
  final trimmed = current.trim();
  if (trimmed.isEmpty || int.tryParse(trimmed) == previousDefault) {
    return '$nextDefault';
  }
  return current;
}

String portHint(ProbeProfile profile) {
  switch (profile.id) {
    case 'nq-tcp':
      return '合作反射 TCP 默认 19090';
    case 'nq-udp':
      return '合作反射 UDP 默认 19091';
    default:
      return '${profile.label} 默认 ${profile.port}';
  }
}

const nonHttpTimeoutMs = 1000;
const httpTimeoutMs = 5000;

int timeoutDefaultFor(String profileId) =>
    profileId == 'http' ? httpTimeoutMs : nonHttpTimeoutMs;

/// An empty timeout, or one that is still the previous profile's default,
/// follows the newly selected profile. A value the user typed stays.
String timeoutAfterProfileChange({
  required String current,
  required int previousDefault,
  required int nextDefault,
}) {
  final trimmed = current.trim();
  if (trimmed.isEmpty || int.tryParse(trimmed) == previousDefault) {
    return '$nextDefault';
  }
  return current;
}

const portHelperText =
    '合作反射 TCP 默认 19090，UDP 默认 19091。只有当前端口仍是上一种类型的默认值或为空时，切换类型才会自动更换。';
