// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter/material.dart';

import '../update/apply_update.dart';
import '../update/update_check.dart';
import '../version.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.allowIPv4,
    required this.allowIPv6,
    required this.autoUpdate,
    required this.onAllowIPv4,
    required this.onAllowIPv6,
    required this.onAutoUpdate,
  });

  final bool allowIPv4;
  final bool allowIPv6;
  final bool autoUpdate;
  final ValueChanged<bool> onAllowIPv4;
  final ValueChanged<bool> onAllowIPv6;
  final ValueChanged<bool> onAutoUpdate;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _allow4;
  late bool _allow6;
  late bool _auto;
  var _checking = false;
  String _message = '';
  UpdateOffer? _offer;

  @override
  void initState() {
    super.initState();
    _allow4 = widget.allowIPv4;
    _allow6 = widget.allowIPv6;
    _auto = widget.autoUpdate;
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = '';
      _offer = null;
    });
    final result = await checkForUpdate();
    if (!mounted) {
      return;
    }
    setState(() {
      _checking = false;
      _message = result.message;
      _offer = result.offer;
    });
  }

  Future<void> _install() async {
    final offer = _offer;
    if (offer == null) {
      return;
    }
    setState(() => _checking = true);
    final message = await installOffer(offer);
    if (!mounted) {
      return;
    }
    setState(() {
      _checking = false;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: const Color(0xFFF3F1EC),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 8, wide ? 24 : 12, 28),
              children: [
                SwitchListTile(
                  title: const Text('允许 IPv4'),
                  subtitle: const Text('关掉以后，解析结果里的 IPv4 不会用来发包。直接填写 IPv4 地址也会被拒绝。'),
                  value: _allow4,
                  onChanged: (value) {
                    setState(() => _allow4 = value);
                    widget.onAllowIPv4(value);
                  },
                ),
                SwitchListTile(
                  title: const Text('允许 IPv6'),
                  subtitle: const Text('关掉以后，解析结果里的 IPv6 不会用来发包。直接填写 IPv6 地址也会被拒绝。'),
                  value: _allow6,
                  onChanged: (value) {
                    setState(() => _allow6 = value);
                    widget.onAllowIPv6(value);
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '两个都关掉时不能开始探测。远程节点会收到同样的选择。1.1.2 的节点还不会遵守这个开关，遇到这种情况会提示升级。',
                    style: TextStyle(color: Color(0xFF5C656B), fontSize: 13, height: 1.4),
                  ),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('自动检查更新'),
                  subtitle: const Text('默认打开。关闭后，启动时不检查，也不会自动下载。'),
                  value: _auto,
                  onChanged: (value) {
                    setState(() => _auto = value);
                    widget.onAutoUpdate(value);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '当前版本 $appVersion（构建 $appBuild）。1.1.2 没有自更新，从 1.1.2 升到 1.1.3 仍要手动安装。从这一版起才会自己检查。先试 GitHub，连不上再试言灸的 Git。\n\n要在没有新版本时试这个功能，可以把环境变量 NQ_UPDATE_GITHUB_API 指到一个同样格式的测试地址，NQ_UPDATE_GITEA_API 是备用。',
                    style: const TextStyle(color: Color(0xFF5C656B), fontSize: 13, height: 1.4),
                  ),
                ),
                if (Platform.isAndroid)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '在 Android 上安装时，系统会弹出安装确认。这一步不能跳过。',
                      style: TextStyle(color: Color(0xFF9A3412), fontSize: 13, height: 1.4),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _checking ? null : _check,
                        child: Text(_checking ? '正在检查' : '检查更新'),
                      ),
                      if (_offer != null)
                        FilledButton(
                          onPressed: _checking ? null : _install,
                          child: const Text('下载并安装'),
                        ),
                    ],
                  ),
                ),
                if (_message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(_message),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
