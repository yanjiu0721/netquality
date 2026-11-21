// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import '../models/session_config.dart';

class CatalogServer {
  const CatalogServer({
    required this.id,
    required this.name,
    required this.confidential,
    this.controlUrl = '',
    this.credential = '',
    this.credentialExpiresAt = '',
  });

  final String id;
  final String name;
  final bool confidential;
  final String controlUrl;
  final String credential;
  final String credentialExpiresAt;
}

class Catalog {
  const Catalog({
    required this.account,
    required this.group,
    required this.servers,
  });

  final String account;
  final String group;
  final List<CatalogServer> servers;

  /// Parses a catalog. Confidential entries drop any address or credential
  /// the server might have included by mistake.
  factory Catalog.parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('目录无效');
    }
    final rawServers = decoded['servers'];
    final servers = <CatalogServer>[];
    if (rawServers is List) {
      for (final item in rawServers) {
        if (item is! Map) {
          continue;
        }
        final confidential = item['confidential'] == true;
        final url = item['controlUrl'] is String ? item['controlUrl'] as String : '';
        final credential = item['credential'] is String
            ? item['credential'] as String
            : '';
        servers.add(
          CatalogServer(
            id: item['id'] is String ? item['id'] as String : '',
            name: item['name'] is String ? item['name'] as String : '未命名',
            confidential: confidential,
            controlUrl: confidential ? '' : url,
            credential: confidential ? '' : credential,
            credentialExpiresAt: confidential
                ? ''
                : (item['credentialExpiresAt'] is String
                      ? item['credentialExpiresAt'] as String
                      : ''),
          ),
        );
      }
    }
    return Catalog(
      account: decoded['account'] is String ? decoded['account'] as String : '',
      group: decoded['group'] is String ? decoded['group'] as String : '',
      servers: servers,
    );
  }
}

class CenterSyncResult {
  const CenterSyncResult({required this.nodes, required this.credentials});

  final List<RemoteNode> nodes;

  /// Node id to short-lived credential. Confidential nodes are absent.
  /// The node's long-lived token is never in this map.
  final Map<String, String> credentials;
}

/// Replaces the servers that belong to [link] with the catalog.
/// Manual nodes and servers from other centers stay. Confidential nodes
/// are stored with an empty address.
CenterSyncResult mergeCenterCatalog({
  required List<RemoteNode> existing,
  required CenterLink link,
  required Catalog catalog,
  required String Function() newId,
}) {
  final kept = [
    for (final node in existing)
      if (!node.fromCenter || node.centerLinkId != link.id) node,
  ];
  final previous = {
    for (final node in existing)
      if (node.fromCenter && node.centerLinkId == link.id) node.serverId: node,
  };
  final credentials = <String, String>{};
  final added = <RemoteNode>[];
  for (final server in catalog.servers) {
    if (server.id.isEmpty) {
      continue;
    }
    final old = previous[server.id];
    final id = old?.id ?? newId();
    final node = RemoteNode(
      id: id,
      name: server.name,
      baseUrl: server.confidential ? '' : server.controlUrl,
      visibility: server.confidential ? 'confidential' : 'center',
      fromCenter: true,
      confidential: server.confidential,
      centerLinkId: link.id,
      serverId: server.id,
    );
    added.add(node);
    if (!server.confidential && server.credential.isNotEmpty) {
      credentials[id] = server.credential;
    }
  }
  return CenterSyncResult(nodes: [...kept, ...added], credentials: credentials);
}

/// Center-issued names cannot be changed on the client.
RemoteNode renameNode(RemoteNode node, String name) {
  if (node.fromCenter) {
    return node;
  }
  return node.copyWith(name: name);
}

bool storedNodeHides(RemoteNode node, String secret) {
  if (!node.confidential || secret.isEmpty) {
    return true;
  }
  final raw = jsonEncode(node.toJson());
  return !raw.contains(secret);
}
