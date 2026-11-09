import 'dart:convert';

import '../protocol/probe_packet.dart';
import 'probe_profile.dart';

class RemoteNode {
  const RemoteNode({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.visibility = '',
  });

  final String id;
  final String name;
  final String baseUrl;
  final String visibility;

  RemoteNode copyWith({String? name, String? baseUrl, String? visibility}) {
    return RemoteNode(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      visibility: visibility ?? this.visibility,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'visibility': visibility,
  };

  factory RemoteNode.fromJson(Map<String, dynamic> json) {
    return RemoteNode(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '未命名节点',
      baseUrl: json['baseUrl'] is String ? json['baseUrl'] as String : '',
      visibility: json['visibility'] is String ? json['visibility'] as String : '',
    );
  }
}

class SessionConfig {
  const SessionConfig({
    required this.remote,
    required this.nodeId,
    required this.nodes,
    required this.host,
    required this.port,
    required this.profileId,
    required this.intervalMs,
    required this.timeoutMs,
    required this.durationSec,
    required this.packetSize,
    required this.dnsName,
    required this.payloadHex,
    required this.expectHex,
  });

  static const defaults = SessionConfig(
    remote: false,
    nodeId: '',
    nodes: [],
    host: '127.0.0.1',
    port: 19090,
    profileId: 'nq-tcp',
    intervalMs: 300,
    timeoutMs: 1000,
    durationSec: 60,
    packetSize: 128,
    dnsName: 'example.com',
    payloadHex: '',
    expectHex: '',
  );

  final bool remote;
  final String nodeId;
  final List<RemoteNode> nodes;
  final String host;
  final int port;
  final String profileId;
  final int intervalMs;
  final int timeoutMs;
  final int durationSec;
  final int packetSize;
  final String dnsName;
  final String payloadHex;
  final String expectHex;

  ProbeProfile get profile => ProbeProfile.byId(profileId);

  RemoteNode? get node {
    for (final item in nodes) {
      if (item.id == nodeId) {
        return item;
      }
    }
    return null;
  }

  String? validate() {
    if (host.trim().isEmpty) {
      return '请填写目标地址';
    }
    if (port < 1 || port > 65535) {
      return '端口需要在 1 到 65535 之间';
    }
    final minInterval = remote ? 200 : 100;
    if (intervalMs < minInterval || intervalMs > 30000) {
      return remote
          ? '远程节点的发送间隔需要在 200 到 30000 毫秒之间'
          : '发送间隔需要在 100 到 30000 毫秒之间';
    }
    if (timeoutMs < 100 || timeoutMs > 15000) {
      return '超时需要在 100 到 15000 毫秒之间';
    }
    if (remote && (durationSec < 1 || durationSec > 300)) {
      return '远程探测时长需要在 1 到 300 秒之间，节点还会再加自己的上限';
    }
    if (profile.needsPacketSize &&
        (packetSize < ProbePacket.headerSize || packetSize > 1400)) {
      if (profileId == 'udp-generic' && (packetSize < 1 || packetSize > 1400)) {
        return '报文大小需要在 1 到 1400 字节之间';
      }
      if (profileId != 'udp-generic') {
        return '报文大小需要在 ${ProbePacket.headerSize} 到 1400 字节之间';
      }
    }
    if (profileId == 'dns' && dnsName.trim().isEmpty) {
      return '请填写要查询的域名';
    }
    if (profileId == 'custom-udp') {
      final payload = _hexError(payloadHex, allowEmpty: false);
      if (payload != null) {
        return '自定义载荷$payload';
      }
      final expect = _hexError(expectHex, allowEmpty: true);
      if (expect != null) {
        return '预期响应$expect';
      }
    }
    if (remote) {
      final selected = node;
      if (selected == null) {
        return '请先添加并选择一个远程节点';
      }
      if (normalizeNodeUrl(selected.baseUrl) == null) {
        return '节点地址需要是 http 或 https，且不能把口令写在地址里';
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'remote': remote,
    'nodeId': nodeId,
    'nodes': nodes.map((node) => node.toJson()).toList(),
    'host': host,
    'port': port,
    'profileId': profileId,
    'intervalMs': intervalMs,
    'timeoutMs': timeoutMs,
    'durationSec': durationSec,
    'packetSize': packetSize,
    'dnsName': dnsName,
    'payloadHex': payloadHex,
    'expectHex': expectHex,
  };

  factory SessionConfig.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'];
    final nodes = <RemoteNode>[];
    if (rawNodes is List) {
      for (final item in rawNodes) {
        if (item is Map) {
          nodes.add(RemoteNode.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return SessionConfig(
      remote: json['remote'] == true,
      nodeId: json['nodeId'] is String ? json['nodeId'] as String : '',
      nodes: nodes,
      host: json['host'] is String ? json['host'] as String : defaults.host,
      port: _asInt(json['port'], defaults.port),
      profileId: json['profileId'] is String
          ? json['profileId'] as String
          : defaults.profileId,
      intervalMs: _asInt(json['intervalMs'], defaults.intervalMs),
      timeoutMs: _asInt(json['timeoutMs'], defaults.timeoutMs),
      durationSec: _asInt(json['durationSec'], defaults.durationSec),
      packetSize: _asInt(json['packetSize'], defaults.packetSize),
      dnsName: json['dnsName'] is String
          ? json['dnsName'] as String
          : defaults.dnsName,
      payloadHex: json['payloadHex'] is String ? json['payloadHex'] as String : '',
      expectHex: json['expectHex'] is String ? json['expectHex'] as String : '',
    );
  }

  static int _asInt(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? fallback;
    }
    return fallback;
  }
}

String? _hexError(String raw, {required bool allowEmpty}) {
  final text = raw.replaceAll(RegExp(r'\s'), '');
  if (text.isEmpty) {
    return allowEmpty ? null : '需要是十六进制';
  }
  if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) {
    return '需要是偶数位的十六进制';
  }
  if (text.length > 2800) {
    return '太长了';
  }
  return null;
}

/// Accepts an operator control URL and refuses credentials embedded in it.
String? normalizeNodeUrl(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return null;
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return null;
  }
  if (uri.userInfo.isNotEmpty) {
    return null;
  }
  final port = uri.hasPort ? ':${uri.port}' : '';
  final path = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
  return '${uri.scheme}://${uri.host}$port$path';
}

bool nodeUrlLooksPublic(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host != 'localhost' &&
      host != '127.0.0.1' &&
      host != '::1' &&
      uri.scheme == 'http';
}

/// Legacy v1 settings stored the echo token beside the host. Migrate the
/// non-secret fields and return the token so the caller can move it out.
({SessionConfig config, String echoToken}) migrateV1(String raw) {
  final json = jsonDecode(raw);
  if (json is! Map) {
    return (config: SessionConfig.defaults, echoToken: '');
  }
  final map = Map<String, dynamic>.from(json);
  final token = map['token'] is String ? map['token'] as String : '';
  final tcp = SessionConfig._asInt(map['tcpPort'], 19090);
  final udp = SessionConfig._asInt(map['udpPort'], 19091);
  final enableTcp = map['enableTcp'] != false;
  return (
    config: SessionConfig(
      remote: false,
      nodeId: '',
      nodes: const [],
      host: map['host'] is String ? map['host'] as String : '127.0.0.1',
      port: enableTcp ? tcp : udp,
      profileId: enableTcp ? 'nq-tcp' : 'nq-udp',
      intervalMs: SessionConfig._asInt(map['intervalMs'], 300),
      timeoutMs: SessionConfig._asInt(map['timeoutMs'], 1000),
      durationSec: 60,
      packetSize: SessionConfig._asInt(map['packetSize'], 128),
      dnsName: 'example.com',
      payloadHex: '',
      expectHex: '',
    ),
    echoToken: token,
  );
}
