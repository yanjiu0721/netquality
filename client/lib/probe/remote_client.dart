import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../metrics/sample_book.dart';
import '../models/session_config.dart';

class RemoteProbe {
  HttpClient? _client;
  String? _jobId;
  Uri? _base;

  Future<void> run({
    required String baseUrl,
    required String nodeToken,
    required ProbeBody body,
    required void Function(ProbeSample sample) onSample,
    required bool Function() cancelled,
  }) async {
    final normalized = normalizeNodeUrl(baseUrl);
    if (normalized == null) {
      throw RemoteException('节点地址需要是 http 或 https，且不能把口令写在地址里');
    }
    _base = Uri.parse(normalized);
    final client = HttpClient();
    _client = client;
    try {
      final created = await _send(
        client,
        'POST',
        _base!.resolve('/v1/jobs'),
        nodeToken,
        utf8.encode(jsonEncode(body.toJson())),
      );
      if (created.status >= 300 && created.status < 400) {
        throw RemoteException('节点地址发生了跳转。请填写最终地址，不要在地址里带口令');
      }
      if (created.status == 401) {
        throw RemoteException('节点口令不正确或未提供');
      }
      if (created.status == 429) {
        throw RemoteException('节点同时探测的任务已达上限');
      }
      if (created.status == 403 || created.status == 400) {
        throw RemoteException(_message(created.body) ?? '节点拒绝了这次探测');
      }
      if (created.status != 201) {
        throw RemoteException('节点没有接受探测（${created.status}）');
      }
      final parsed = jsonDecode(created.body);
      if (parsed is! Map || parsed['jobId'] is! String) {
        throw RemoteException('节点返回的任务无效');
      }
      _jobId = parsed['jobId'] as String;
      if (cancelled()) {
        return;
      }
      await _stream(client, nodeToken, onSample, cancelled);
    } on RemoteException {
      rethrow;
    } on SocketException {
      if (!cancelled()) {
        throw RemoteException('连不上节点。请检查地址、端口和防火墙');
      }
    } on HandshakeException {
      throw RemoteException('TLS 握手失败。请检查证书，或改用正确的 HTTPS 地址');
    } on RedirectException {
      throw RemoteException('节点地址发生了跳转。请填写最终地址，不要在地址里带口令');
    } on HttpException {
      if (!cancelled()) {
        throw RemoteException('节点连接中断');
      }
    } on TimeoutException {
      if (!cancelled()) {
        throw RemoteException('节点没有及时响应');
      }
    } finally {
      await stop(nodeToken);
    }
  }

  Future<void> stop(String nodeToken) async {
    final client = _client;
    final id = _jobId;
    final base = _base;
    _jobId = null;
    if (client != null && id != null && base != null) {
      try {
        await _send(client, 'DELETE', base.resolve('/v1/jobs/$id'), nodeToken, const []);
      } on Object {
        // The stream ending already asks the node to drop the job.
      }
    }
    client?.close(force: true);
    _client = null;
  }

  Future<void> _stream(
    HttpClient client,
    String nodeToken,
    void Function(ProbeSample sample) onSample,
    bool Function() cancelled,
  ) async {
    final request = await client.getUrl(_base!.resolve('/v1/jobs/$_jobId/stream'));
    request.followRedirects = false;
    _auth(request, nodeToken);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode == 401) {
      throw RemoteException('节点口令不正确或未提供');
    }
    if (response.statusCode != 200) {
      throw RemoteException('无法接收节点上的探测结果');
    }
    var buffer = '';
    await for (final chunk in response.transform(utf8.decoder)) {
      if (cancelled()) {
        return;
      }
      buffer += chunk;
      while (buffer.contains('\n\n')) {
        final split = buffer.indexOf('\n\n');
        final block = buffer.substring(0, split);
        buffer = buffer.substring(split + 2);
        final sample = _sampleFromBlock(block);
        if (sample != null) {
          onSample(sample);
        }
      }
    }
  }
}

class ProbeBody {
  const ProbeBody({
    required this.target,
    required this.port,
    required this.profile,
    required this.intervalMs,
    required this.timeoutMs,
    required this.durationSec,
    required this.packetSize,
    required this.echoToken,
    required this.dnsName,
    required this.payloadHex,
    required this.expectHex,
  });

  final String target;
  final int port;
  final String profile;
  final int intervalMs;
  final int timeoutMs;
  final int durationSec;
  final int packetSize;
  final String echoToken;
  final String dnsName;
  final String payloadHex;
  final String expectHex;

  Map<String, Object?> toJson() => {
    'target': target,
    'port': port,
    'profile': profile,
    'intervalMs': intervalMs,
    'timeoutMs': timeoutMs,
    'durationSec': durationSec,
    'packetSize': packetSize,
    'echoToken': echoToken,
    'dnsName': dnsName,
    'payloadHex': payloadHex,
    'expectHex': expectHex,
  };
}

class RemoteException implements Exception {
  RemoteException(this.message);
  final String message;

  @override
  String toString() => message;
}

class NodeInfo {
  const NodeInfo({required this.visibility, required this.authRequired});

  final String visibility;
  final bool authRequired;
}

Future<NodeInfo> fetchNodeInfo(String baseUrl) async {
  final normalized = normalizeNodeUrl(baseUrl);
  if (normalized == null) {
    throw RemoteException('节点地址需要是 http 或 https，且不能把口令写在地址里');
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(normalized).resolve('/v1/info'));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 8));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw RemoteException('读不到节点信息');
    }
    final json = jsonDecode(body);
    if (json is! Map) {
      throw RemoteException('节点信息无效');
    }
    return NodeInfo(
      visibility: json['visibility'] is String ? json['visibility'] as String : '',
      authRequired: json['authRequired'] == true,
    );
  } on RemoteException {
    rethrow;
  } on SocketException {
    throw RemoteException('连不上节点');
  } on HandshakeException {
    throw RemoteException('TLS 握手失败');
  } finally {
    client.close(force: true);
  }
}

Future<({int status, String body})> _send(
  HttpClient client,
  String method,
  Uri uri,
  String nodeToken,
  List<int> bytes,
) async {
  final request = await client.openUrl(method, uri);
  request.followRedirects = false;
  request.headers.contentType = ContentType.json;
  _auth(request, nodeToken);
  request.add(bytes);
  final response = await request.close().timeout(const Duration(seconds: 15));
  final body = await response.transform(utf8.decoder).join();
  return (status: response.statusCode, body: body);
}

void _auth(HttpClientRequest request, String nodeToken) {
  if (nodeToken.isNotEmpty) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $nodeToken');
  }
}

String? _message(String body) {
  try {
    final json = jsonDecode(body);
    if (json is Map && json['message'] is String) {
      return json['message'] as String;
    }
  } on FormatException {
    return null;
  }
  return null;
}

ProbeSample? _sampleFromBlock(String block) {
  String? data;
  for (final line in block.split('\n')) {
    if (line.startsWith('data: ')) {
      data = line.substring(6);
    }
  }
  if (data == null || data == '{}') {
    return null;
  }
  try {
    final json = jsonDecode(data);
    if (json is! Map) {
      return null;
    }
    final sample = ProbeSample.fromJson(Map<String, dynamic>.from(json));
    if (sample.status.isEmpty || sample.status == 'pending') {
      return null;
    }
    return sample;
  } on FormatException {
    return null;
  }
}
