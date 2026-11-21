// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import '../models/session_config.dart';
import 'catalog.dart';

class CenterClientException implements Exception {
  CenterClientException(this.message);
  final String message;

  @override
  String toString() => message;
}

Future<String> loginCenter({
  required String baseUrl,
  required String account,
  required String password,
}) async {
  final body = await _send(
    baseUrl,
    'POST',
    '/v1/center/login',
    '',
    {'account': account.trim(), 'password': password},
  );
  final token = body['token'];
  if (token is! String || token.isEmpty) {
    throw CenterClientException('中心没有返回口令');
  }
  return token;
}

Future<Catalog> fetchCatalog({
  required String baseUrl,
  required String token,
}) async {
  final body = await _send(baseUrl, 'GET', '/v1/center/catalog', token, null);
  return Catalog.parse(jsonEncode(body));
}

Future<Map<String, dynamic>> _send(
  String baseUrl,
  String method,
  String path,
  String token,
  Map<String, Object?>? jsonBody,
) async {
  final normalized = normalizeNodeUrl(baseUrl);
  if (normalized == null) {
    throw CenterClientException('中心地址需要是 http 或 https，且不能把口令写在地址里');
  }
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse(normalized).resolve(path),
    );
    request.followRedirects = false;
    if (token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(jsonBody)));
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw CenterClientException('中心地址发生了跳转。请填写最终的 HTTPS 地址');
    }
    if (response.statusCode == 401) {
      throw CenterClientException('中心口令不正确，或账号密码不对');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CenterClientException(_message(text) ?? '中心拒绝了这次请求');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw CenterClientException('中心返回的内容无效');
    }
    return Map<String, dynamic>.from(decoded);
  } on CenterClientException {
    rethrow;
  } on SocketException {
    throw CenterClientException('连不上中心。请检查地址和防火墙');
  } on HandshakeException {
    throw CenterClientException('TLS 握手失败。请改用正确的 HTTPS 地址');
  } on FormatException {
    throw CenterClientException('中心返回的内容无效');
  } finally {
    client.close(force: true);
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
