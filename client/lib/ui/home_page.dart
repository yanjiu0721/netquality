import 'dart:async';

import 'package:flutter/material.dart';

import '../models/probe_profile.dart';
import '../models/session_config.dart';
import '../probe/endpoint_picker.dart';
import '../probe/probe_controller.dart';
import '../probe/remote_client.dart';
import '../storage/app_store.dart';
import '../storage/token_vault.dart';
import 'format.dart';
import 'quality_charts.dart';

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
  var _remote = false;
  var _profileId = ProbeProfile.nqTcp.id;
  var _nodeId = '';
  var _nodes = <RemoteNode>[];
  var _ready = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_rebuild);
    _load();
  }

  Future<void> _load() async {
    _vault = await openTokenVault();
    final loaded = await _store.load();
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
      _echo.text = (echo == null || echo.isEmpty) ? loaded.legacyEcho : echo;
      _ready = true;
    });
    if (loaded.legacyEcho.isNotEmpty && (echo == null || echo.isEmpty)) {
      await _vault.write(echoTokenKey, loaded.legacyEcho);
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
    );
  }

  Future<void> _persist() async {
    await _store.save(_config());
    await _vault.write(echoTokenKey, _echo.text);
  }

  Future<void> _start() async {
    await _persist();
    final config = _config();
    final nodeToken = config.node == null
        ? ''
        : (await _vault.read(nodeTokenKey(config.node!.id)) ?? '');
    await _controller.start(config, nodeToken: nodeToken, echoToken: _echo.text);
  }

  void _changeProfile(String? id) {
    if (id == null) {
      return;
    }
    final previous = ProbeProfile.byId(_profileId);
    final next = ProbeProfile.byId(id);
    setState(() {
      if (_port.text.trim() == '${previous.port}') {
        _port.text = '${next.port}';
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
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: ListView(
              padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 8, wide ? 24 : 12, 28),
              children: [
                _card(
                  title: '探测来源',
                  child: _source(view, wide),
                ),
                _card(
                  title: '目标',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _pair(
                        wide,
                        _field(_host, '目标地址', '域名或 IP'),
                        _field(_port, '端口', '1–65535'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: const Key('profile'),
                        initialValue: _profileId,
                        decoration: const InputDecoration(labelText: '探测类型'),
                        items: [
                          for (final item in ProbeProfile.all)
                            DropdownMenuItem(value: item.id, child: Text(item.label)),
                        ],
                        onChanged: view.running ? null : _changeProfile,
                      ),
                      const SizedBox(height: 8),
                      Text(profile.blurb, style: const TextStyle(color: muted, fontSize: 13)),
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
                        _field(_interval, '间隔（毫秒）', _remote ? '至少 200' : '至少 100'),
                        _field(_timeout, '超时（毫秒）', '100–15000'),
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
                _card(title: '结果', child: _result(view)),
                QualityCharts(
                  samples: view.samples,
                  rateLabel: view.rateLabel,
                  running: view.running,
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
    final selected = _nodes.cast<RemoteNode?>().followedBy(const [null]).firstWhere(
      (node) => node?.id == _nodeId,
      orElse: () => null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('本机'), icon: Icon(Icons.phone_android)),
            ButtonSegment(value: true, label: Text('远程节点'), icon: Icon(Icons.dns_outlined)),
          ],
          selected: {_remote},
          onSelectionChanged: view.running
              ? null
              : (value) => setState(() => _remote = value.first),
        ),
        const SizedBox(height: 8),
        Text(
          _remote
              ? '由选中的节点向目标发包，这台设备只负责控制和显示。'
              : '由这台设备直接向目标发包。可以探测本机上的反射器。',
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
            OutlinedButton(
              onPressed: view.running ? null : _manageNodes,
              child: const Text('管理节点'),
            ),
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

  String _nodeLabel(RemoteNode node) {
    final vis = visibilityLabel(node.visibility);
    return '${node.name} · $vis';
  }

  Widget _result(ProbeView view) {
    final summary = view.summary;
    final rate = view.rateLabel == '探测无应答'
        ? summary.probeLossPct
        : view.rateLabel == '失败率'
        ? summary.failurePct
        : summary.unknownPct;
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
            if (view.targetAddress != null) _chip('发往 ${view.targetAddress}'),
            _chip('延迟 ${formatMs(summary.rttMs)}'),
            _chip('抖动 ${formatMs(summary.jitterMs)}'),
            _chip('${view.rateLabel} ${formatPct(rate)}'),
          ],
        ),
        if (view.targetIsFake) ...[
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
        Text(summaryLine(summary), style: const TextStyle(color: muted, fontSize: 13)),
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

  Future<void> _check(RemoteNode node) async {
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
    final next = [for (final item in _nodes) if (item.id != node.id) item];
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
                  title: Text(_nodes.isEmpty ? '' : '${node.name} · ${visibilityLabel(node.visibility)}'),
                  subtitle: Text(node.baseUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(onPressed: () => _check(node), child: const Text('检查')),
                      TextButton(onPressed: () => _delete(node), child: const Text('删除')),
                    ],
                  ),
                ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: '节点地址',
                  hintText: 'https://probe.example:8443',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '节点口令（公开节点留空）',
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
        TextButton(onPressed: _save, child: const Text('添加节点')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
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
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: ink)),
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
}) {
  return TextField(
    controller: controller,
    obscureText: secret,
    decoration: InputDecoration(labelText: label, hintText: hint),
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
