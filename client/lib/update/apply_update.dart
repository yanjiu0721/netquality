// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';

import '../version.dart';
import 'installer.dart';
import 'update_check.dart';

class UpdateResult {
  const UpdateResult({required this.message, this.offer});

  final String message;
  final UpdateOffer? offer;
}

const platformChannel = MethodChannel('dev.netquality/platform');

Future<UpdateResult> checkForUpdate() async {
  final arch = await _arch();
  if (arch.isEmpty) {
    return const UpdateResult(message: '认不出这台设备的系统或 CPU，没有下载安装包');
  }
  final endpoints = UpdateEndpoints(
    github: Platform.environment['NQ_UPDATE_GITHUB_API'] ??
        UpdateEndpoints.githubDefault,
    gitea: Platform.environment['NQ_UPDATE_GITEA_API'] ??
        UpdateEndpoints.giteaDefault,
  );
  final check = await findUpdate(
    current: appVersion,
    endpoints: endpoints,
    os: _os(),
    arch: arch,
    fetch: (url) => _getText(url),
  );
  if (check.offer == null) {
    return UpdateResult(message: check.message);
  }
  return UpdateResult(
    message: '发现 ${check.offer!.version}。可以下载并覆盖安装。',
    offer: check.offer,
  );
}

Future<String> installOffer(UpdateOffer offer) async {
  final bytes = await _getBytes(Uri.parse(offer.assetUrl));
  if (bytes == null) {
    return '安装包没有下载下来';
  }
  var checksumNote = '';
  if (offer.checksumUrl != null && offer.checksumUrl!.isNotEmpty) {
    final sums = await _getText(Uri.parse(offer.checksumUrl!));
    if (sums == null || !checksumMatches(sums, offer.assetName, bytes)) {
      return '校验和没有对上，已停止安装';
    }
    checksumNote = '校验通过。';
  } else {
    checksumNote = '这次发布没有校验和文件，已按下载的包继续。';
  }
  if (Platform.isAndroid) {
    final temp = await Directory.systemTemp.createTemp('nq-update-');
    final file = File('${temp.path}/updates/${offer.assetName}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await platformChannel.invokeMethod<void>('installApk', {'path': file.path});
    return '$checksumNote安装包已交给系统。请在系统弹出的确认里完成安装，这一步不能跳过。';
  }
  final extracted = await Directory.systemTemp.createTemp('nq-update-');
  extractArchive(bytes, offer.assetName, extracted);
  final installDir = File(Platform.resolvedExecutable).parent;
  if (Platform.isWindows) {
    await _windowsReplace(extracted, installDir);
    return '$checksumNote已下载。程序即将退出，随后覆盖安装并重新打开。';
  }
  copyIntoInstall(extracted, installDir);
  try {
    await Process.run('chmod', ['755', Platform.resolvedExecutable]);
  } on ProcessException {
    // The existing file is often already executable.
  }
  await Process.start(
    Platform.resolvedExecutable,
    const [],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

Future<void> _windowsReplace(Directory extracted, Directory installDir) async {
  final script = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}nq-update-$pid.ps1',
  );
  final from = _ps(extracted.path);
  final to = _ps(installDir.path);
  final exe = _ps(Platform.resolvedExecutable);
  await script.writeAsString('''
\$target = $pid
\$from = $from
\$to = $to
while (Get-Process -Id \$target -ErrorAction SilentlyContinue) {
  Start-Sleep -Milliseconds 200
}
Copy-Item -Path (Join-Path \$from '*') -Destination \$to -Recurse -Force
Start-Process -FilePath $exe
''');
  await Process.start('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
  ]);
  exit(0);
}

String _ps(String path) => "'${path.replaceAll("'", "''")}'";

String _os() {
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  return 'linux';
}

Future<String> _arch() async {
  if (Platform.isAndroid) {
    try {
      final abi = await platformChannel.invokeMethod<String>('abi');
      return abi ?? '';
    } on PlatformException {
      return '';
    }
  }
  switch (Abi.current()) {
    case Abi.linuxX64:
    case Abi.windowsX64:
      return 'amd64';
    case Abi.linuxArm64:
    case Abi.windowsArm64:
      return 'arm64';
    default:
      return '';
  }
}

Future<String?> _getText(Uri url) async {
  final bytes = await _getBytes(url);
  if (bytes == null) {
    return null;
  }
  return String.fromCharCodes(bytes);
}

Future<List<int>?> _getBytes(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return chunks;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}
