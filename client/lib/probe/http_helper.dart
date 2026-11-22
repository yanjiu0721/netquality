// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import '../metrics/sample_book.dart';

const helperMissingNote =
    '本机 HTTP 探测需要 Go 程序 netquality-reflector，现在没有找到，所以探测没有开始。请把探测来源改成「远程节点」。桌面端也可以把 netquality-reflector 放在程序旁边，或设置环境变量 NQ_PROBE_HELPER。';

const helperStartFailedNote =
    '本机 HTTP 探测找到了 netquality-reflector，但没有启动成功，所以探测没有开始。请把探测来源改成「远程节点」。桌面端也可以检查这个程序能否运行，或改用环境变量 NQ_PROBE_HELPER。';

/// Thrown before any sample is recorded when the local HTTP engine cannot run.
class LocalHttpHelperException implements Exception {
  const LocalHttpHelperException(this.message);

  final String message;
}

bool isLocalHttpHelperFailure(Outcome outcome) {
  return outcome.status == Outcome.error &&
      (outcome.note == helperMissingNote ||
          outcome.note == helperStartFailedNote);
}

/// Tests set this to skip the search next to the executable.
String? Function()? locateProbeHelperOverride;

String? locateProbeHelper() {
  final override = locateProbeHelperOverride;
  if (override != null) {
    return override();
  }
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

/// Null when the local Go helper can be started. Otherwise a Chinese reason
/// that already tells the user to switch the source to a remote node.
Future<String?> localHttpBlockedReason({String? binary}) async {
  final path = binary ?? locateProbeHelper();
  if (path == null || path.isEmpty || !File(path).existsSync()) {
    return helperMissingNote;
  }
  try {
    final process = await Process.start(path, const ['-mode', 'helper']);
    process.kill();
    process.exitCode.ignore();
    return null;
  } catch (_) {
    return helperStartFailedNote;
  }
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
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.query,
        note: helperMissingNote,
      );
    }
    final Process process;
    try {
      process = await Process.start(path, const ['-mode', 'helper']);
    } catch (_) {
      return const Outcome(
        status: Outcome.error,
        kind: Outcome.query,
        note: helperStartFailedNote,
      );
    }
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
