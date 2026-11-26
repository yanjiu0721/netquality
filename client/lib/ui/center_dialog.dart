// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../center/catalog.dart';
import '../center/center_client.dart';
import '../models/session_config.dart';
import 'expandable_hint.dart';

class AddedCenter {
  const AddedCenter({
    required this.link,
    required this.token,
    required this.catalog,
  });

  final CenterLink link;
  final String token;
  final Catalog catalog;
}

Future<AddedCenter?> showCenterAddDialog(BuildContext context) {
  return showDialog<AddedCenter>(
    context: context,
    builder: (context) => const _CenterAddDialog(),
  );
}

class _CenterAddDialog extends StatefulWidget {
  const _CenterAddDialog();

  @override
  State<_CenterAddDialog> createState() => _CenterAddDialogState();
}

class _CenterAddDialogState extends State<_CenterAddDialog> {
  final _url = TextEditingController();
  final _account = TextEditingController();
  final _token = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  String? _hint;

  @override
  void dispose() {
    _url.dispose();
    _account.dispose();
    _token.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      var token = _token.text.trim();
      if (token.isEmpty) {
        if (_password.text.isEmpty) {
          setState(() => _hint = '请填写口令。如果中心要求密码，也可以只填账号和密码。');
          return;
        }
        token = await loginCenter(
          baseUrl: _url.text,
          account: _account.text,
          password: _password.text,
        );
      }
      final catalog = await fetchCatalog(baseUrl: _url.text, token: token);
      final stored = normalizeNodeUrl(_url.text);
      if (stored == null) {
        setState(() => _hint = '中心地址需要是 http 或 https，且不能把口令写在地址里');
        return;
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        AddedCenter(
          link: CenterLink(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            url: stored,
            account: _account.text.trim(),
          ),
          token: token,
          catalog: catalog,
        ),
      );
    } on CenterClientException catch (error) {
      setState(() => _hint = error.message);
    } on Object {
      setState(() => _hint = '没有完成添加');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('一键添加服务器'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '点一次确认，会把这个口令能用的服务器全部加进来。显示名由中心决定，这里不能改。保密服务器只保存名称，地址留在中心。',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '中心地址',
                hintText: 'https://中心:8443',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _account,
              decoration: const InputDecoration(labelText: '账号'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '口令',
                hintText: '已有口令时填写',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                hintText: '还没有口令时填写',
              ),
            ),
            const ExpandableHint(text: '中心要求密码、手里还没有口令时填写。'),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Text(_hint!, style: const TextStyle(color: Color(0xFF9A3412))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '正在获取' : '获取并添加'),
        ),
      ],
    );
  }
}
