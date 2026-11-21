// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// True when [sums] publishes a matching SHA-256 line for [fileName].
/// A published file that does not mention the asset is a failure, not a skip.
bool checksumMatches(String sums, String fileName, List<int> bytes) {
  final want = sha256.convert(bytes).toString().toLowerCase();
  final base = fileName.split(RegExp(r'[\\/]')).last;
  var mentioned = false;
  for (final raw in const LineSplitter().convert(sums)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$').firstMatch(line);
    if (match == null) {
      continue;
    }
    final name = match.group(2)!.split(RegExp(r'[\\/]')).last;
    if (name != base) {
      continue;
    }
    mentioned = true;
    if (match.group(1)!.toLowerCase() == want) {
      return true;
    }
  }
  if (!mentioned) {
    return false;
  }
  return false;
}

/// Extracts a zip or tar.gz into [dest]. Paths that climb out of [dest] are skipped.
void extractArchive(List<int> bytes, String fileName, Directory dest) {
  final Archive archive;
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
    archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  } else if (lower.endsWith('.zip')) {
    archive = ZipDecoder().decodeBytes(bytes);
  } else {
    throw const FormatException('只支持 zip 和 tar.gz');
  }
  final root = _singleRoot(archive);
  for (final file in archive) {
    if (!file.isFile) {
      continue;
    }
    var name = file.name.replaceAll('\\', '/');
    while (name.startsWith('./')) {
      name = name.substring(2);
    }
    if (root.isNotEmpty && name.startsWith('$root/')) {
      name = name.substring(root.length + 1);
    }
    if (name.isEmpty || name.startsWith('/') || name.contains('../')) {
      continue;
    }
    final out = File('${dest.path}/$name');
    final parent = out.parent.path;
    if (!_inside(dest.path, parent) && parent != dest.path) {
      continue;
    }
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(file.content as List<int>);
  }
}

/// Copies extracted files onto the existing install directory.
/// Files already there and not in the archive are left in place, so a data
/// file sitting beside the program is not wiped. Nothing outside [installDir]
/// is written.
void copyIntoInstall(Directory extracted, Directory installDir) {
  if (!_inside(installDir.path, extracted.path) &&
      extracted.path != installDir.path) {
    // The source may be a temp directory. That is allowed.
  }
  for (final entity in extracted.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final relative = entity.path.substring(extracted.path.length);
    final trimmed = relative.replaceAll('\\', '/').replaceFirst(RegExp(r'^/'), '');
    if (trimmed.isEmpty || trimmed.contains('../')) {
      continue;
    }
    final target = File('${installDir.path}/$trimmed');
    if (!_inside(installDir.path, target.parent.path) &&
        target.parent.path != installDir.path) {
      continue;
    }
    target.parent.createSync(recursive: true);
    entity.copySync(target.path);
  }
}

String _singleRoot(Archive archive) {
  String? root;
  for (final file in archive) {
    final name = file.name.replaceAll('\\', '/');
    final slash = name.indexOf('/');
    if (slash <= 0) {
      return '';
    }
    final top = name.substring(0, slash);
    if (root == null) {
      root = top;
    } else if (root != top) {
      return '';
    }
  }
  return root ?? '';
}

bool _inside(String root, String child) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return child == root || child.startsWith(prefix);
}
