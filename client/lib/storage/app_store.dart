import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session_config.dart';
import 'token_vault.dart';

class AppStore {
  static const _key = 'netquality.settings.v2';
  static const _legacy = 'netquality.settings.v1';

  Future<({SessionConfig config, String legacyEcho})> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return (
            config: SessionConfig.fromJson(Map<String, dynamic>.from(decoded)),
            legacyEcho: '',
          );
        }
      } on FormatException {
        return (config: SessionConfig.defaults, legacyEcho: '');
      }
    }
    final legacy = prefs.getString(_legacy);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        final migrated = migrateV1(legacy);
        await save(migrated.config);
        await prefs.remove(_legacy);
        return (config: migrated.config, legacyEcho: migrated.echoToken);
      } on FormatException {
        return (config: SessionConfig.defaults, legacyEcho: '');
      }
    }
    return (config: SessionConfig.defaults, legacyEcho: '');
  }

  Future<void> save(SessionConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }
}

Future<TokenVault> openTokenVault() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final vault = FileTokenVault(File('${dir.path}/node-tokens.json'));
    await vault.load();
    return vault;
  } on Object {
    return MemoryTokenVault();
  }
}
