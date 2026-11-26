import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../center/catalog.dart';
import '../center/center_client.dart';
import '../models/node_edit.dart';
import '../models/port_field.dart';
import '../models/probe_profile.dart';
import '../models/session_config.dart';
import '../models/target_history.dart';
import '../probe/endpoint_picker.dart';
import '../probe/probe_controller.dart';
import '../probe/remote_client.dart';
import '../storage/app_store.dart';
import '../storage/token_vault.dart';
import '../update/apply_update.dart';
import 'address_text.dart';
import 'center_dialog.dart';
import 'format.dart';
import 'history_page.dart';
import 'metric_guide_page.dart';
import 'metrics_panel.dart';
import 'quality_charts.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = ProbeController();
  final _store = AppStore();
  TokenVault _vault = MemoryTokenVault();
  final _host = TextEditingController(text: SessionConfig.defaults.host);
  final _port = TextEditingController(text: '${SessionConfig.defaults.port}');
  final _interval = TextEditingController(text: '300');
  final _timeout = TextEditingController(text: '1000');
  final _duration = TextEditingController(text: '60');
  final _size = TextEditingController(text: '128');
  final _echo = TextEditingController();
  final _dns = TextEditingController(text: 'example.com');
  final _payload = TextEditingController();
  final _expect = TextEditingController();
  final _httpResolve = TextEditingController();
  final _httpBody = TextEditingController();
  final _httpReferer = TextEditingController();
  final _httpUserAgent = TextEditingController();
  final _httpCookies = TextEditingController();
  final _httpRedirects = TextEditingController(text: '5');
  var _httpVersion = 'auto';
  var _httpMethod = 'GET';
  var _allow4 = true;
  var _allow6 = true;
  var _autoUpdate = true;
  var _centers = <CenterLink>[];
  var _history = TargetHistory.empty;
  var _centerHint = '';
  var _remote = false;
  var _profileId = ProbeProfile.nqTcp.id;
  var _nodeId = '';
  var _nodes = <RemoteNode>[];
  var _ready = false;
  var _idSeq = 0;
  var _formEpoch = 0;
  String? _portBeforeHttp;
  String? _profileBeforeHttp;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_rebuild);
    _load();
  }

  Future<void> _load() async {
    _vault = await openTokenVault();
    final loaded = await _store.load();
    final history = await _store.loadHistory();
    final echo = await _vault.read(echoTokenKey);
    if (!mounted) {
      return;
    }
    final config = loaded.config;
    setState(() {
      _remote = config.remote;
      _nodeId = config.nodeId;
      _nodes = config.nodes;
      _profileId = config.profileId;
      _host.text = config.host;
      _port.text = '${config.port}';
      _interval.text = '${config.intervalMs}';
      _timeout.text = '${config.timeoutMs}';
      _duration.text = '${config.durationSec}';
      _size.text = '${config.packetSize}';
      _dns.text = config.dnsName;
      _payload.text = config.payloadHex;
      _expect.text = config.expectHex;
      _allow4 = config.allowIPv4;
      _allow6 = config.allowIPv6;
      _autoUpdate = config.autoUpdate;
      _httpVersion = config.httpVersion;
      _httpMethod = config.httpMethod;
      _httpResolve.text = config.httpResolve;
      _httpBody.text = config.httpBody;
      _httpReferer.text = config.httpReferer;
      _httpUserAgent.text = config.httpUserAgent;
      _httpCookies.text = config.httpCookies;
      _httpRedirects.text = '${config.httpMaxRedirects}';
      _centers = config.centers;
      _history = history;
      _echo.text = (echo == null || echo.isEmpty) ? loaded.legacyEcho : echo;
      _ready = true;
    });
    if (loaded.legacyEcho.isNotEmpty && (echo == null || echo.isEmpty)) {
      await _vault.write(echoTokenKey, loaded.legacyEcho);
    }
    if (config.autoUpdate && Platform.environment['FLUTTER_TEST'] != 'true') {
      unawaited(_launchUpdate());
    }
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_controller.stop());
    unawaited(_persist());
    _controller.removeListener(_rebuild);
    _controller.dispose();
    for (final field in [
      _host,
      _port,
      _interval,
      _timeout,
      _duration,
      _size,
      _echo,
      _dns,
      _payload,
      _expect,
      _httpResolve,
      _httpBody,
      _httpReferer,
      _httpUserAgent,
      _httpCookies,
      _httpRedirects,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  SessionConfig _config() {
    return SessionConfig(
      remote: _remote,
      nodeId: _nodeId,
      nodes: _nodes,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 0,
      profileId: _profileId,
      intervalMs: int.tryParse(_interval.text.trim()) ?? 0,
      timeoutMs: int.tryParse(_timeout.text.trim()) ?? 0,
      durationSec: int.tryParse(_duration.text.trim()) ?? 0,
      packetSize: int.tryParse(_size.text.trim()) ?? 0,
      dnsName: _dns.text.trim(),
      payloadHex: _payload.text.trim(),
      expectHex: _expect.text.trim(),
      allowIPv4: _allow4,
      allowIPv6: _allow6,
      autoUpdate: _autoUpdate,
      httpVersion: _httpVersion,
      httpResolve: _httpResolve.text.trim(),
      httpMethod: _httpMethod,
      httpBody: _httpBody.text,
      httpReferer: _httpReferer.text.trim(),
      httpUserAgent: _httpUserAgent.text.trim(),
      httpCookies: _httpCookies.text,
      httpMaxRedirects: int.tryParse(_httpRedirects.text.trim()) ?? 5,
      centers: _centers,
    );
  }

  Future<void> _persist() async {
    await _store.save(_config());
    await _vault.write(echoTokenKey, _echo.text);
  }

  Future<void> _start() async {
    await _persist();
    final config = _config();
    if (config.validate() == null) {
      final httpTarget = config.httpTarget;
      _history = _history.add(
        TargetEntry(
          host: httpTarget?.url ?? config.host,
          port: httpTarget?.port ?? config.port,
          profileId: config.profileId,
          httpUrl: httpTarget?.url ?? '',
          method: config.profileId == 'http' ? config.httpMethod : '',
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _store.saveHistory(_history);
    }
    final node = config.node;
    final nodeToken = node == null
        ? ''
        : (await _vault.read(
                node.confidential
                    ? centerTokenKey(node.centerLinkId)
                    : nodeTokenKey(node.id),
              ) ??
              '');
    await _controller.start(
      config,
      nodeToken: nodeToken,
      echoToken: _echo.text,
    );
  }

  void _changeProfile(String? id) {
    if (id == null || id == _profileId) {
      return;
    }
    final previous = ProbeProfile.byId(_profileId);
    final next = ProbeProfile.byId(id);
    setState(() {
      _timeout.text = timeoutAfterProfileChange(
        current: _timeout.text,
        previousDefault: timeoutDefaultFor(_profileId),
        nextDefault: timeoutDefaultFor(id),
      );
      if (id == 'http') {
        _portBeforeHttp = _port.text;
        _profileBeforeHttp = _profileId;
      } else if (_profileId == 'http' &&
          _portBeforeHttp != null &&
          _profileBeforeHttp != null) {
        _port.text = portAfterProfileChange(
          current: _portBeforeHttp!,
          previousDefault: ProbeProfile.byId(_profileBeforeHttp!).port,
          nextDefault: next.port,
        );
        _portBeforeHttp = null;
        _profileBeforeHttp = null;
      } else {
        final currentPort = int.tryParse(_port.text.trim());
        var previousDefault = previous.port;
        if (_profileId == 'http' && (currentPort == 80 || currentPort == 443)) {
          previousDefault = currentPort!;
        }
        _port.text = portAfterProfileChange(
          current: _port.text,
          previousDefault: previousDefault,
          nextDefault: next.port,
        );
      }
      _profileId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = _controller.view;
    final profile = ProbeProfile.byId(_profileId);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Scaffold(
      appBar: AppBar(
        title: const Text('网络质量探测'),
        backgroundColor: const Color(0xFFF3F1EC),
        actions: [
          PopupMenuButton<String>(
            tooltip: '说明',
            onSelected: (value) {
              if (value == 'settings') {
                _openSettings();
                return;
              }
              final page = value == 'history'
                  ? const HistoryPage()
                  : const MetricGuidePage();
              Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => page));
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'settings', child: Text('设置')),
              PopupMenuItem(value: 'metrics', child: Text('指标说明')),
              PopupMenuItem(value: 'history', child: Text('更新历史')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                wide ? 24 : 12,
                8,
                wide ? 24 : 12,
                28,
              ),
              children: [
                _card(title: '探测来源', child: _source(view, wide)),
                _card(
                  title: '目标',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (profile.id == 'http')
                        _hostRow(
                          view.running,
                          'https://example.com:2025/ 或 example.com',
                          helper:
                              '只填主机名或 IP 时按 http:// 和端口 80。完整网址使用其中的协议、端口和路径。',
                          fieldKey: const Key('target-field'),
                        )
                      else
                        _pair(
                          wide,
                          _hostRow(view.running, '域名、IP，或 http(s) 地址'),
                          _field(
                            _port,
                            '端口',
                            portHint(profile),
                            fieldKey: const Key('port-field'),
                            helper: portHelperText,
                          ),
                        ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: _formEpoch == 0
                            ? const Key('profile')
                            : Key('profile-$_formEpoch'),
                        initialValue: _profileId,
                        decoration: const InputDecoration(labelText: '探测类型'),
                        items: [
                          for (final item in ProbeProfile.all)
                            DropdownMenuItem(
                              value: item.id,
                              child: Text(item.label),
                            ),
                        ],
                        onChanged: view.running ? null : _changeProfile,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        profile.blurb,
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                      if (profile.id == 'http') ..._httpFields(view.running),
                    ],
                  ),
                ),
                _card(
                  title: '参数',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _pair(
                        wide,
                        _field(
                          _interval,
                          '间隔（毫秒）',
                          _remote ? '至少 200' : '至少 100',
                        ),
                        _field(
                          _timeout,
                          '超时（毫秒）',
                          '100–15000',
                          fieldKey: const Key('timeout-field'),
                          helper: profile.id == 'http'
                              ? 'HTTP 默认 5000 毫秒'
                              : null,
                        ),
                      ),
                      if (profile.needsPacketSize) ...[
                        const SizedBox(height: 12),
                        _field(_size, '报文大小（字节）', '最大 1400'),
                      ],
                      if (_remote) ...[
                        const SizedBox(height: 12),
                        _field(_duration, '时长（秒）', '到点后节点会停止'),
                      ],
                      if (profile.needsEchoToken) ...[
                        const SizedBox(height: 12),
                        _field(
                          _echo,
                          '目标回显口令',
                          '可选，只放进探测包，和节点口令不是同一个',
                          secret: true,
                        ),
                      ],
                      if (profile.id == 'dns') ...[
                        const SizedBox(height: 12),
                        _field(_dns, '查询域名', '例如 example.com'),
                      ],
                      if (profile.id == 'custom-udp') ...[
                        const SizedBox(height: 12),
                        _field(_payload, '载荷（十六进制）', '例如 0102'),
                        const SizedBox(height: 12),
                        _field(_expect, '响应需以此开头（十六进制，可空）', '不填则任意响应都算成功'),
                      ],
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: !_ready
                      ? null
                      : view.running
                      ? _controller.stop
                      : _start,
                  child: Text(view.running ? '停止探测' : '开始探测'),
                ),
                if (view.banner != null) ...[
                  const SizedBox(height: 12),
                  _banner(view.banner!),
                ],
                const SizedBox(height: 12),
                _card(
                  title: '结果',
                  child: _result(
                    view,
                    view.profileId.isEmpty ? profile.id : view.profileId,
                  ),
                ),
                if (view.report != null)
                  SessionSummaryCard(
                    report: view.report!,
                    profileId: view.report!.profileId,
                  ),
                QualityCharts(
                  samples: view.samples,
                  rateLabel: view.rateLabel,
                  running: view.running,
                  sessionId: view.sessionId,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MetricGuidePage(),
                        ),
                      ),
                      child: const Text('指标说明'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const HistoryPage(),
                        ),
                      ),
                      child: const Text('更新历史'),
                    ),
                  ],
                ),
                const Text(
                  '延迟用发包一侧的单调时钟计算。远程探测时，这个时间在节点上量好再传回来，不包含手机到节点的控制通道耗时。TCP 超时不是物理丢包。没有协议应答的 UDP 记为无应答/未知，不会在探测完成前显示 100%。',
                  style: TextStyle(color: muted, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _source(ProbeView view, bool wide) {
    final selected = _nodes
        .cast<RemoteNode?>()
        .followedBy(const [null])
        .firstWhere((node) => node?.id == _nodeId, orElse: () => null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('本机'),
              icon: Icon(Icons.phone_android),
            ),
            ButtonSegment(
              value: true,
              label: Text('远程节点'),
              icon: Icon(Icons.dns_outlined),
            ),
          ],
          selected: {_remote},
          onSelectionChanged: view.running
              ? null
              : (value) => setState(() => _remote = value.first),
        ),
        const SizedBox(height: 8),
        Text(
          _remote ? '由选中的节点向目标发包，这台设备只负责控制和显示。' : '由这台设备直接向目标发包。可以探测本机上的反射器。',
          style: const TextStyle(color: muted, fontSize: 13),
        ),
        if (_remote) ...[
          const SizedBox(height: 12),
          _pair(
            wide,
            DropdownButtonFormField<String>(
              key: const Key('node-selector'),
              initialValue: selected == null ? '' : selected.id,
              decoration: const InputDecoration(labelText: '节点'),
              items: [
                const DropdownMenuItem(value: '', child: Text('未选择')),
                for (final node in _nodes)
                  DropdownMenuItem(
                    value: node.id,
                    child: Text(_nodeLabel(node)),
                  ),
              ],
              onChanged: view.running
                  ? null
                  : (value) => setState(() => _nodeId = value ?? ''),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: view.running ? null : _manageNodes,
                  child: const Text('管理节点'),
                ),
                OutlinedButton(
                  onPressed: view.running ? null : _addCenter,
                  child: const Text('一键添加服务器'),
                ),
              ],
            ),
          ),
          if (_centers.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final link in _centers) _centerTile(link, view.running),
          ],
          if (_centerHint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_centerHint, style: const TextStyle(fontSize: 13)),
            ),
          if (selected != null && nodeUrlLooksPublic(selected.baseUrl))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '这个控制地址没有使用 HTTPS。口令会暴露在链路上，请改用 TLS 或 HTTPS 反向代理。',
                style: TextStyle(color: Color(0xFF9A3412), fontSize: 12),
              ),
            ),
        ],
      ],
    );
  }

  List<Widget> _httpFields(bool running) {
    return [
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: ValueKey('http-version-$_httpVersion-$_formEpoch'),
        initialValue: _httpVersion,
        decoration: const InputDecoration(labelText: '协议'),
        items: const [
          DropdownMenuItem(value: 'auto', child: Text('自动（HTTP/2，可降到 1.1）')),
          DropdownMenuItem(value: '1.1', child: Text('仅 HTTP/1.1')),
          DropdownMenuItem(value: '2', child: Text('仅 HTTP/2')),
          DropdownMenuItem(value: '3', child: Text('仅 HTTP/3')),
        ],
        onChanged: running
            ? null
            : (value) => setState(() => _httpVersion = value ?? 'auto'),
      ),
      const SizedBox(height: 8),
      _field(_httpResolve, '指定解析', '可选。Host 和 SNI 仍用上面的地址，连接改走这里的 IP 或主机名'),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: ValueKey('http-method-$_httpMethod-$_formEpoch'),
        initialValue: _httpMethod,
        decoration: const InputDecoration(labelText: '方法'),
        items: const [
          DropdownMenuItem(value: 'GET', child: Text('GET')),
          DropdownMenuItem(value: 'POST', child: Text('POST')),
        ],
        onChanged: running
            ? null
            : (value) => setState(() => _httpMethod = value ?? 'GET'),
      ),
      if (_httpMethod == 'POST') ...[
        const SizedBox(height: 8),
        _field(_httpBody, '请求体', '可选'),
      ],
      const SizedBox(height: 8),
      _field(_httpReferer, 'Referer', '可选'),
      const SizedBox(height: 8),
      _field(_httpUserAgent, 'User-Agent', '可选'),
      const SizedBox(height: 8),
      _field(_httpCookies, 'Cookies', '可选', secret: true),
      const SizedBox(height: 8),
      _field(_httpRedirects, '最大跳转次数', '默认 5，0 到 20'),
    ];
  }

  String _httpSummary(Map<String, String> detail) {
    final parts = [
      if (detail['httpVersion'] != null) 'HTTP/${detail['httpVersion']}',
      if (detail['statusCode'] != null) '状态 ${detail['statusCode']}',
      if (detail['finalUrl'] != null) detail['finalUrl']!,
    ];
    final times = [
      if (detail['dnsMs'] != null) 'DNS ${detail['dnsMs']} ms',
      if (detail['connectMs'] != null) '连接 ${detail['connectMs']} ms',
      if (detail['tlsMs'] != null) 'TLS ${detail['tlsMs']} ms',
      if (detail['ttfbMs'] != null) 'TTFB ${detail['ttfbMs']} ms',
      if (detail['totalMs'] != null) '总计 ${detail['totalMs']} ms',
    ];
    final chain = detail['redirects'];
    return [
      parts.join(' · '),
      if (times.isNotEmpty) times.join('，'),
      if (chain != null && chain.isNotEmpty) '跳转 $chain',
    ].where((part) => part.isNotEmpty).join('\n');
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          allowIPv4: _allow4,
          allowIPv6: _allow6,
          autoUpdate: _autoUpdate,
          onAllowIPv4: (value) {
            setState(() => _allow4 = value);
            unawaited(_persist());
          },
          onAllowIPv6: (value) {
            setState(() => _allow6 = value);
            unawaited(_persist());
          },
          onAutoUpdate: (value) {
            setState(() => _autoUpdate = value);
            unawaited(_persist());
          },
        ),
      ),
    );
  }

  Future<void> _launchUpdate() async {
    final result = await checkForUpdate();
    final offer = result.offer;
    if (offer == null || !mounted || !_autoUpdate) {
      return;
    }
    await installOffer(offer);
  }

  Future<void> _showHistory() async {
    if (_history.entries.isEmpty) {
      setState(() => _centerHint = '');
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('最近目标'),
          content: const Text('还没有保存过目标。点「开始探测」之后，这里会记下地址、端口和类型。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('最近目标'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _history.entries.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_history.entries[i].label),
                  onTap: () {
                    _applyHistory(_history.entries[i]);
                    Navigator.pop(context);
                  },
                  trailing: IconButton(
                    tooltip: '删除',
                    onPressed: () async {
                      _history = _history.removeAt(i);
                      await _store.saveHistory(_history);
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                      await _showHistory();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              _history = _history.clear();
              await _store.saveHistory(_history);
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('全部清除'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _applyHistory(TargetEntry entry) {
    setState(() {
      _formEpoch += 1;
      _portBeforeHttp = null;
      _profileBeforeHttp = null;
      _profileId = entry.profileId;
      _host.text = entry.profileId == 'http' && entry.httpUrl.isNotEmpty
          ? entry.httpUrl
          : entry.host;
      _port.text = '${entry.port}';
      if (entry.profileId == 'http' && entry.method.isNotEmpty) {
        _httpMethod = entry.method;
      }
      if (entry.profileId == 'http') {
        final current = int.tryParse(_timeout.text.trim());
        if (current == null || current == timeoutDefaultFor('nq-tcp')) {
          _timeout.text = '${timeoutDefaultFor('http')}';
        }
      }
    });
  }

  Widget _hostRow(bool running, String hint, {String? helper, Key? fieldKey}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _field(
            _host,
            '目标地址',
            hint,
            helper: helper,
            fieldKey: fieldKey,
          ),
        ),
        IconButton(
          key: const Key('target-history'),
          tooltip: '最近目标',
          onPressed: running ? null : _showHistory,
          icon: const Icon(Icons.history),
        ),
      ],
    );
  }

  String _newId() {
    _idSeq += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-$_idSeq';
  }

  Future<void> _addCenter() async {
    final added = await showCenterAddDialog(context);
    if (added == null) {
      return;
    }
    var link = added.link;
    for (final existing in _centers) {
      if (existing.url == added.link.url &&
          existing.account == added.link.account) {
        link = existing;
        break;
      }
    }
    await _vault.write(centerTokenKey(link.id), added.token);
    await _applyCatalog(
      link,
      added.catalog,
      '已添加 ${added.catalog.servers.length} 台服务器',
    );
  }

  Future<void> _refreshCenter(CenterLink link) async {
    try {
      final token = await _vault.read(centerTokenKey(link.id)) ?? '';
      final catalog = await fetchCatalog(baseUrl: link.url, token: token);
      await _applyCatalog(link, catalog, '已按中心重新同步');
    } on CenterClientException catch (error) {
      setState(() => _centerHint = error.message);
    }
  }

  Future<void> _removeCenter(CenterLink link) async {
    final gone = [
      for (final node in _nodes)
        if (node.centerLinkId == link.id) node.id,
    ];
    for (final id in gone) {
      await _vault.delete(nodeTokenKey(id));
    }
    await _vault.delete(centerTokenKey(link.id));
    setState(() {
      _centers = [
        for (final item in _centers)
          if (item.id != link.id) item,
      ];
      _nodes = [
        for (final node in _nodes)
          if (node.centerLinkId != link.id) node,
      ];
      if (!_nodes.any((node) => node.id == _nodeId)) {
        _nodeId = '';
      }
      _centerHint = '已移除这个中心口令及其服务器';
    });
    await _persist();
  }

  Future<void> _applyCatalog(
    CenterLink link,
    Catalog catalog,
    String hint,
  ) async {
    final before = {
      for (final node in _nodes)
        if (node.centerLinkId == link.id) node.id,
    };
    final merged = mergeCenterCatalog(
      existing: _nodes,
      link: link,
      catalog: catalog,
      newId: _newId,
    );
    final after = {
      for (final node in merged.nodes)
        if (node.centerLinkId == link.id) node.id,
    };
    for (final id in before.difference(after)) {
      await _vault.delete(nodeTokenKey(id));
    }
    for (final node in merged.nodes) {
      if (node.centerLinkId == link.id && node.confidential) {
        await _vault.delete(nodeTokenKey(node.id));
      }
    }
    for (final entry in merged.credentials.entries) {
      await _vault.write(nodeTokenKey(entry.key), entry.value);
    }
    setState(() {
      if (!_centers.any((item) => item.id == link.id)) {
        _centers = [..._centers, link];
      }
      _nodes = merged.nodes;
      _centerHint = hint;
    });
    await _persist();
  }

  Widget _centerTile(CenterLink link, bool running) {
    final servers = [
      for (final node in _nodes)
        if (node.centerLinkId == link.id) node,
    ];
    final title = link.account.isEmpty
        ? link.url
        : '${link.account} · ${link.url}';
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${servers.length} 台服务器'),
      children: [
        for (final node in servers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(node.name),
            subtitle: Text(
              node.confidential ? '地址由中心代为连接，本机不保存。' : node.baseUrl,
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: running ? null : () => _refreshCenter(link),
              child: const Text('刷新'),
            ),
            TextButton(
              onPressed: running ? null : () => _removeCenter(link),
              child: const Text('移除'),
            ),
          ],
        ),
      ],
    );
  }

  String _nodeLabel(RemoteNode node) {
    final vis = visibilityLabel(node.visibility);
    return '${node.name} · $vis';
  }

  Widget _result(ProbeView view, String profileId) {
    final summary = view.summary;
    final address = describeAddress(
      resolved: view.resolved,
      usedAddress: view.usedAddress,
      usedFamily: view.usedFamily,
      tryingAddress: view.tryingAddress,
      tryingFamily: view.tryingFamily,
      fallbackText: view.fallbackText,
      addressUnreported: view.addressUnreported,
      usedIsFake: view.usedIsFake,
    );
    final motd = view.detail['motd'];
    final version = view.detail['version'];
    final players = view.detail['players'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(view.phase),
            _chip('来源 ${view.sourceLabel}'),
            if (view.targetHost.isNotEmpty) _chip(view.targetHost),
          ],
        ),
        const SizedBox(height: 8),
        MetricsPanel(
          summary: summary,
          profileId: profileId,
          elapsed: view.elapsed,
        ),
        if (address.trying != null) ...[
          const SizedBox(height: 8),
          Text(address.trying!, style: const TextStyle(color: ink)),
        ],
        if (address.used != null) ...[
          const SizedBox(height: 8),
          Text(address.used!, style: const TextStyle(color: ink)),
        ],
        if (address.resolved != null) ...[
          const SizedBox(height: 8),
          Text(
            address.resolved!,
            style: const TextStyle(color: muted, fontSize: 13),
          ),
        ],
        if (address.unreported != null) ...[
          const SizedBox(height: 8),
          Text(
            address.unreported!,
            style: const TextStyle(color: Color(0xFF9A3412)),
          ),
        ],
        if (address.fallback != null) ...[
          const SizedBox(height: 8),
          Text(address.fallback!, style: const TextStyle(color: ink)),
        ],
        if (address.fake) ...[
          const SizedBox(height: 8),
          const Text(
            clashFakeIpNote,
            style: TextStyle(color: Color(0xFF9A3412), fontSize: 13),
          ),
        ],
        if (view.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(view.note, style: const TextStyle(color: ink)),
        ],
        if (view.detail['httpVersion'] != null ||
            view.detail['statusCode'] != null) ...[
          const SizedBox(height: 8),
          Text(_httpSummary(view.detail), style: const TextStyle(color: ink)),
        ],
        if (motd != null || version != null || players != null) ...[
          const SizedBox(height: 8),
          Text(
            [
              if (motd != null) 'MOTD $motd',
              if (version != null) '版本 $version',
              if (players != null) '人数 $players',
            ].join(' · '),
            style: const TextStyle(color: ink),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          summaryLine(summary),
          style: const TextStyle(color: muted, fontSize: 13),
        ),
      ],
    );
  }

  Future<void> _manageNodes() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _NodeDialog(
        nodes: _nodes,
        vault: _vault,
        onChanged: (nodes, selected) {
          setState(() {
            _nodes = nodes;
            if (selected != null) {
              _nodeId = selected;
              _remote = true;
            } else if (_nodes.every((node) => node.id != _nodeId)) {
              _nodeId = '';
            }
          });
          unawaited(_persist());
        },
      ),
    );
  }
}

class _NodeDialog extends StatefulWidget {
  const _NodeDialog({
    required this.nodes,
    required this.vault,
    required this.onChanged,
  });

  final List<RemoteNode> nodes;
  final TokenVault vault;
  final void Function(List<RemoteNode> nodes, String? selected) onChanged;

  @override
  State<_NodeDialog> createState() => _NodeDialogState();
}

class _NodeDialogState extends State<_NodeDialog> {
  late List<RemoteNode> _nodes = [...widget.nodes];
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _token = TextEditingController();
  String? _editingId;
  String? _hint;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = normalizeNodeUrl(_url.text);
    if (_name.text.trim().isEmpty || url == null) {
      setState(() => _hint = '请填写名称，以及不带口令的 http 或 https 地址');
      return;
    }
    final editing = _editingId;
    if (editing != null) {
      RemoteNode? previous;
      for (final node in _nodes) {
        if (node.id == editing) {
          previous = node;
        }
      }
      if (previous == null) {
        return;
      }
      final next = applyNodeEdit(
        previous,
        name: _name.text.trim(),
        baseUrl: url,
      );
      final replaced = await saveEditedNodeToken(
        widget.vault,
        editing,
        _token.text,
      );
      setState(() {
        _nodes = [
          for (final node in _nodes)
            if (node.id == editing) next else node,
        ];
        _editingId = null;
        _hint = replaced ? '已更新，口令已替换，仍只留在本机。' : '已更新。口令留空，原来的口令未改。';
        _name.clear();
        _url.clear();
        _token.clear();
      });
      widget.onChanged(_nodes, editing);
      return;
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final node = RemoteNode(id: id, name: _name.text.trim(), baseUrl: url);
    await widget.vault.write(nodeTokenKey(id), _token.text.trim());
    setState(() {
      _nodes = [..._nodes, node];
      _hint = '已保存。口令只留在本机。';
      _name.clear();
      _url.clear();
      _token.clear();
    });
    widget.onChanged(_nodes, id);
  }

  void _beginEdit(RemoteNode node) {
    if (node.fromCenter) {
      setState(() => _hint = '中心分配的名称和地址不能在这里修改。需要变更时，回到中心刷新。');
      return;
    }
    setState(() {
      _editingId = node.id;
      _name.text = node.name;
      _url.text = node.baseUrl;
      _token.clear();
      _hint = '正在修改「${node.name}」。口令留空则保留已保存的口令，不会显示原口令。';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingId = null;
      _name.clear();
      _url.clear();
      _token.clear();
      _hint = null;
    });
  }

  Future<void> _check(RemoteNode node) async {
    if (node.confidential) {
      setState(() => _hint = '这台服务器由中心代为连接，本机没有地址，不能直接检查。');
      return;
    }
    try {
      final info = await fetchNodeInfo(node.baseUrl);
      final next = [
        for (final item in _nodes)
          if (item.id == node.id)
            item.copyWith(visibility: info.visibility)
          else
            item,
      ];
      setState(() {
        _nodes = next;
        _hint = info.authRequired
            ? '这个节点是私有的，请求必须带正确的节点口令，否则不会向目标发包。'
            : '这个节点是公开的，不需要口令。它仍然有并发、时长和带宽上限。';
      });
      widget.onChanged(next, node.id);
    } on RemoteException catch (error) {
      setState(() => _hint = error.message);
    }
  }

  Future<void> _delete(RemoteNode node) async {
    await widget.vault.delete(nodeTokenKey(node.id));
    final next = [
      for (final item in _nodes)
        if (item.id != node.id) item,
    ];
    setState(() => _nodes = next);
    widget.onChanged(next, null);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('远程节点'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '节点口令和目标回显口令是两回事。服务器没配置节点口令时，它是公开节点；配置了就必须校验，错误口令不会发出任何探测。',
                style: TextStyle(fontSize: 13, color: muted),
              ),
              const SizedBox(height: 12),
              for (final node in _nodes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${node.name} · ${visibilityLabel(node.visibility)}',
                  ),
                  subtitle: Text(
                    node.confidential ? '地址由中心代为连接，本机不保存。' : node.baseUrl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      if (!node.fromCenter)
                        TextButton(
                          key: Key('edit-node-${node.id}'),
                          onPressed: () => _beginEdit(node),
                          child: const Text('编辑'),
                        ),
                      TextButton(
                        onPressed: () => _check(node),
                        child: const Text('检查'),
                      ),
                      TextButton(
                        onPressed: () => _delete(node),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ),
              TextField(
                key: const Key('node-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('node-url'),
                controller: _url,
                decoration: const InputDecoration(
                  labelText: '节点地址',
                  hintText: 'https://probe.example:8443',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('node-token'),
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _editingId == null ? '节点口令（公开节点留空）' : '新口令（留空则保留）',
                  helperText: _editingId == null
                      ? null
                      : '留空则保留已保存的口令，不会显示原口令。',
                ),
              ),
              if (_hint != null) ...[
                const SizedBox(height: 8),
                Text(_hint!, style: const TextStyle(fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_editingId != null)
          TextButton(onPressed: _cancelEdit, child: const Text('取消编辑')),
        TextButton(
          key: const Key('node-save'),
          onPressed: _save,
          child: Text(_editingId == null ? '添加节点' : '保存修改'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

Widget _card({required String title, required Widget child}) {
  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: line),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, color: ink),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

Widget _field(
  TextEditingController controller,
  String label,
  String hint, {
  bool secret = false,
  Key? fieldKey,
  String? helper,
}) {
  return TextField(
    key: fieldKey,
    controller: controller,
    obscureText: secret,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
    ),
  );
}

Widget _pair(bool wide, Widget left, Widget right) {
  if (!wide) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [left, const SizedBox(height: 12), right],
    );
  }
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: left),
      const SizedBox(width: 12),
      Expanded(child: right),
    ],
  );
}

Widget _chip(String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFE7EEF5),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12, color: ink)),
  );
}

Widget _banner(String text) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF1E8),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFF0C9B0)),
    ),
    child: Text(text, style: const TextStyle(color: Color(0xFF9A3412))),
  );
}
