// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

/// An HTTP probe target. The separate port field is not used.
class HttpTarget {
  const HttpTarget({
    required this.url,
    required this.host,
    required this.port,
    required this.scheme,
  });

  /// Canonical absolute URL. Default ports are omitted.
  final String url;

  /// Hostname or IP, without brackets.
  final String host;
  final int port;
  final String scheme;
}

HttpTarget? parseHttpTarget(String raw) => readHttpTarget(raw).target;

String? httpTargetError(String raw) => readHttpTarget(raw).error;

({HttpTarget? target, String? error}) readHttpTarget(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return (target: null, error: '请填写目标地址');
  }
  if (text.contains('://')) {
    final uri = Uri.tryParse(text);
    if (uri == null) {
      return (target: null, error: _portOrUrlError(text));
    }
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return (target: null, error: 'HTTP 目标需要是主机名或 http/https 网址');
    }
    return _fromUri(uri);
  }
  final cut = _splitCut(text);
  final hostport = cut < 0 ? text : text.substring(0, cut);
  final rest = cut < 0 ? '' : text.substring(cut);
  if (hostport.isEmpty) {
    return (target: null, error: 'HTTP 目标需要是主机名或 http/https 网址');
  }
  var bracketed = hostport;
  if (':'.allMatches(hostport).length >= 2 && !hostport.startsWith('[')) {
    bracketed = '[$hostport]';
  }
  final uri = Uri.tryParse('http://$bracketed$rest');
  if (uri == null || uri.host.isEmpty || uri.scheme != 'http') {
    return (target: null, error: _portOrUrlError(text));
  }
  return _fromUri(uri);
}

({HttpTarget? target, String? error}) _fromUri(Uri uri) {
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  if (port < 1 || port > 65535) {
    return (target: null, error: '端口需要在 1 到 65535 之间');
  }
  final built = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: port,
    path: uri.path.isEmpty ? '/' : uri.path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  );
  return (
    target: HttpTarget(
      url: built.toString(),
      host: uri.host,
      port: port,
      scheme: uri.scheme,
    ),
    error: null,
  );
}

int _splitCut(String text) {
  final slash = text.indexOf('/');
  final query = text.indexOf('?');
  if (slash < 0) {
    return query;
  }
  if (query < 0) {
    return slash;
  }
  return slash < query ? slash : query;
}

String _portOrUrlError(String text) {
  final match = RegExp(r':(\d+)(?=[/?#]|$)').firstMatch(text);
  if (match != null) {
    final port = int.tryParse(match.group(1)!);
    if (port == null || port < 1 || port > 65535) {
      return '端口需要在 1 到 65535 之间';
    }
  }
  return 'HTTP 目标需要是主机名或 http/https 网址';
}
