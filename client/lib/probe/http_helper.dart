// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import '../metrics/sample_book.dart';

const helperMissingNote =
    '本机 HTTP 探测使用和节点相同的 Go 引擎。请把 netquality-reflector 放在程序旁边，或设置环境变量 NQ_PROBE_HELPER。远程节点不受影响。';

String? locateProbeHelper() {
  final env = Platform.environment['NQ_PROBE_HELPER'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return env;
  }
  final dir = File(Platform.resolvedExecutable).parent;
  final names = Platform.isWindows
      ? const ['netquality-reflector.exe', 'netquality-helper.exe']
      : const ['netquality-reflector', 'netquality-helper'];
  for (final name in names) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    if (file.existsSync()) {
      return file.path;
    }
  }
  return null;
}

Outcome outcomeFromHelper(String line) {
  try {
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.query,
        note: '探测引擎返回的内容无效',
      );
    }
    final detail = <String, String>{};
    final rawDetail = decoded['detail'];
    if (rawDetail is Map) {
      rawDetail.forEach((key, value) {
        if (key is String && value != null) {
          detail[key] = '$value';
        }
      });
    }
    return Outcome(
      status: decoded['status'] is String
          ? decoded['status'] as String
          : Outcome.error,
      kind: decoded['kind'] is String
          ? decoded['kind'] as String
          : Outcome.query,
      rttMs: decoded['rttMs'] is num
          ? (decoded['rttMs'] as num).toDouble()
          : null,
      note: decoded['note'] is String ? decoded['note'] as String : '',
      detail: detail,
    );
  } on FormatException {
    return const Outcome(
      status: Outcome.error,
      kind: Outcome.query,
      note: '探测引擎返回的内容无效',
    );
  }
}

/// One long-running helper process. Each line is one HTTP sample.
class HttpHelperSession {
  HttpHelperSession({this.binary});

  final String? binary;
  Process? _process;
  final _lines = <String>[];
  var _closed = false;

  Future<Outcome> probe(Map<String, Object?> request) async {
    final started = await _ensure();
    if (started != null) {
      return started;
    }
    final process = _process;
    if (process == null) {
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.query,
        note: helperMissingNote,
      );
    }
    process.stdin.writeln(jsonEncode(request));
    final line = await _nextLine();
    if (line == null) {
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.query,
        note: '探测引擎没有返回结果',
      );
    }
    return outcomeFromHelper(line);
  }

  Future<Outcome?> _ensure() async {
    if (_process != null) {
      return null;
    }
    final path = binary ?? locateProbeHelper();
    if (path == null) {
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.query,
        note: helperMissingNote,
      );
    }
    final process = await Process.start(path, const ['-mode', 'helper']);
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isNotEmpty) {
            _lines.add(line);
          }
        });
    return null;
  }

  Future<String?> _nextLine() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (_lines.isNotEmpty) {
        return _lines.removeAt(0);
      }
      if (_closed) {
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  Future<void> close() async {
    _closed = true;
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
    }
  }
}
