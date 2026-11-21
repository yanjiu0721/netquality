import 'dart:convert';

import '../protocol/probe_packet.dart';
import 'ip_family.dart';
import 'probe_profile.dart';

class RemoteNode {
  const RemoteNode({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.visibility = '',
    this.fromCenter = false,
    this.confidential = false,
    this.centerLinkId = '',
    this.serverId = '',
  });

  final String id;
  final String name;
  final String baseUrl;
  final String visibility;
  final bool fromCenter;
  final bool confidential;
  final String centerLinkId;
  final String serverId;

  RemoteNode copyWith({
    String? name,
    String? baseUrl,
    String? visibility,
    bool? fromCenter,
    bool? confidential,
    String? centerLinkId,
    String? serverId,
  }) {
    final hidden = confidential ?? this.confidential;
    return RemoteNode(
      id: id,
      name: name ?? this.name,
      baseUrl: hidden ? '' : (baseUrl ?? this.baseUrl),
      visibility: visibility ?? this.visibility,
      fromCenter: fromCenter ?? this.fromCenter,
      confidential: hidden,
      centerLinkId: centerLinkId ?? this.centerLinkId,
      serverId: serverId ?? this.serverId,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': confidential ? '' : baseUrl,
    'visibility': visibility,
    'fromCenter': fromCenter,
    'confidential': confidential,
    'centerLinkId': centerLinkId,
    'serverId': serverId,
  };

  factory RemoteNode.fromJson(Map<String, dynamic> json) {
    final confidential = json['confidential'] == true;
    return RemoteNode(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '未命名节点',
      baseUrl: confidential
          ? ''
          : (json['baseUrl'] is String ? json['baseUrl'] as String : ''),
      visibility: json['visibility'] is String ? json['visibility'] as String : '',
      fromCenter: json['fromCenter'] == true,
      confidential: confidential,
      centerLinkId: json['centerLinkId'] is String
          ? json['centerLinkId'] as String
          : '',
      serverId: json['serverId'] is String ? json['serverId'] as String : '',
    );
  }
}

class CenterLink {
  const CenterLink({
    required this.id,
    required this.url,
    required this.account,
  });

  final String id;
  final String url;
  final String account;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url,
    'account': account,
  };

  factory CenterLink.fromJson(Map<String, dynamic> json) {
    return CenterLink(
      id: json['id'] is String ? json['id'] as String : '',
      url: json['url'] is String ? json['url'] as String : '',
      account: json['account'] is String ? json['account'] as String : '',
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
    this.allowIPv4 = true,
    this.allowIPv6 = true,
    this.autoUpdate = true,
    this.httpVersion = 'auto',
    this.httpResolve = '',
    this.httpMethod = 'GET',
    this.httpBody = '',
    this.httpReferer = '',
    this.httpUserAgent = '',
    this.httpCookies = '',
    this.httpMaxRedirects = 5,
    this.centers = const [],
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
  final bool allowIPv4;
  final bool allowIPv6;
  final bool autoUpdate;
  final String httpVersion;
  final String httpResolve;
  final String httpMethod;
  final String httpBody;
  final String httpReferer;
  final String httpUserAgent;
  final String httpCookies;
  final int httpMaxRedirects;
  final List<CenterLink> centers;

  CenterLink? centerLink(String id) {
    for (final link in centers) {
      if (link.id == id) {
        return link;
      }
    }
    return null;
  }

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
    final family = familyRefusal(host, v4: allowIPv4, v6: allowIPv6);
    if (family != null) {
      return family;
    }
    if (profileId == 'http' && httpResolve.trim().isNotEmpty) {
      final resolveFamily = familyRefusal(
        httpResolve,
        v4: allowIPv4,
        v6: allowIPv6,
      );
      if (resolveFamily != null) {
        return resolveFamily.replaceFirst('目标', '指定解析');
      }
    }
    if (host.trim().isEmpty) {
      return '请填写目标地址';
    }
    if (profileId == 'http') {
      final method = httpMethod.trim().toUpperCase();
      if (method != 'GET' && method != 'POST') {
        return 'HTTP 方法只支持 GET 和 POST';
      }
      if (httpMaxRedirects < 0 || httpMaxRedirects > 20) {
        return '跳转次数需要在 0 到 20 之间';
      }
      const versions = {'auto', '1.1', '2', '3'};
      if (!versions.contains(httpVersion)) {
        return 'HTTP 版本需要是自动、1.1、2 或 3';
      }
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
      if (selected.confidential) {
        final link = centerLink(selected.centerLinkId);
        if (link == null || normalizeNodeUrl(link.url) == null) {
          return '保密节点需要一个可用的中心地址';
        }
      } else if (normalizeNodeUrl(selected.baseUrl) == null) {
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
    'allowIPv4': allowIPv4,
    'allowIPv6': allowIPv6,
    'autoUpdate': autoUpdate,
    'httpVersion': httpVersion,
    'httpResolve': httpResolve,
    'httpMethod': httpMethod,
    'httpBody': httpBody,
    'httpReferer': httpReferer,
    'httpUserAgent': httpUserAgent,
    'httpCookies': httpCookies,
    'httpMaxRedirects': httpMaxRedirects,
    'centers': centers.map((link) => link.toJson()).toList(),
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
      allowIPv4: json['allowIPv4'] is bool ? json['allowIPv4'] as bool : true,
      allowIPv6: json['allowIPv6'] is bool ? json['allowIPv6'] as bool : true,
      autoUpdate: json['autoUpdate'] is bool ? json['autoUpdate'] as bool : true,
      httpVersion: json['httpVersion'] is String
          ? json['httpVersion'] as String
          : 'auto',
      httpResolve: json['httpResolve'] is String
          ? json['httpResolve'] as String
          : '',
      httpMethod: json['httpMethod'] is String
          ? json['httpMethod'] as String
          : 'GET',
      httpBody: json['httpBody'] is String ? json['httpBody'] as String : '',
      httpReferer: json['httpReferer'] is String
          ? json['httpReferer'] as String
          : '',
      httpUserAgent: json['httpUserAgent'] is String
          ? json['httpUserAgent'] as String
          : '',
      httpCookies: json['httpCookies'] is String
          ? json['httpCookies'] as String
          : '',
      httpMaxRedirects: _asInt(json['httpMaxRedirects'], 5),
      centers: _centers(json['centers']),
    );
  }

  static List<CenterLink> _centers(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return [
      for (final item in raw)
        if (item is Map) CenterLink.fromJson(Map<String, dynamic>.from(item)),
    ];
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
