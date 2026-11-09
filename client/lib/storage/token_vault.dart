import 'dart:convert';
import 'dart:io';

/// Stores node-control tokens and the target echo token outside preferences.
///
/// The file lives in the app's private support directory. On Unix it is
/// created with mode 0600. Tokens are never written into URLs or logs.
abstract class TokenVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryTokenVault implements TokenVault {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    if (value.isEmpty) {
      _values.remove(key);
      return;
    }
    _values[key] = value;
  }
}

class FileTokenVault implements TokenVault {
  FileTokenVault(this.file);

  final File file;
  final Map<String, String> _values = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    if (!await file.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (key is String && value is String && value.isNotEmpty) {
            _values[key] = value;
          }
        });
      }
    } on FormatException {
      _values.clear();
    }
  }

  @override
  Future<void> delete(String key) async {
    await load();
    _values.remove(key);
    await _flush();
  }

  @override
  Future<String?> read(String key) async {
    await load();
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await load();
    if (value.isEmpty) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await _flush();
  }

  Future<void> _flush() async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_values), flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } on ProcessException {
        // The app directory is already private on Android.
      }
    }
  }
}

const echoTokenKey = 'target-echo-token';

String nodeTokenKey(String nodeId) => 'node-token.$nodeId';
