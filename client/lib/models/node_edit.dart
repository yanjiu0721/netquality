// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import '../storage/token_vault.dart';
import 'session_config.dart';

/// Blank means "keep the token already stored". A non-blank value replaces it.
/// The saved token is never returned here.
String? replacementNodeToken(String entered) {
  final trimmed = entered.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

/// Writes a replacement token. Returns false when the existing secret is kept.
Future<bool> saveEditedNodeToken(
  TokenVault vault,
  String id,
  String entered,
) async {
  final next = replacementNodeToken(entered);
  if (next == null) {
    return false;
  }
  await vault.write(nodeTokenKey(id), next);
  return true;
}

/// Keeps [RemoteNode.id]. Changing the control URL clears a cached visibility
/// check because it may now be a different server. The token is not part of
/// this object.
RemoteNode applyNodeEdit(
  RemoteNode node, {
  required String name,
  required String baseUrl,
}) {
  final urlChanged = node.baseUrl != baseUrl;
  return node.copyWith(
    name: name,
    baseUrl: baseUrl,
    visibility: urlChanged ? '' : node.visibility,
  );
}
