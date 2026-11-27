// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

/// Versions that exist as this release or as a real Git tag / GitHub Release.
/// Unpublished earlier behavior mentioned inside the 1.1.1 notes is not given
/// its own entry.
class ReleaseEntry {
  const ReleaseEntry({
    required this.version,
    required this.title,
    required this.source,
    required this.points,
    this.published,
    this.tag,
  });

  final String version;
  final String title;
  final String source;
  final String? published;

  /// Release tag, when this entry came from a forge. Bundled entries omit it.
  final String? tag;
  final List<String> points;

  Map<String, Object?> toJson() => {
    'version': version,
    'title': title,
    'source': source,
    'published': published,
    'tag': tag,
    'points': points,
  };

  factory ReleaseEntry.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    final points = <String>[];
    if (rawPoints is List) {
      for (final item in rawPoints) {
        if (item is String && item.trim().isNotEmpty) {
          points.add(item);
        }
      }
    }
    return ReleaseEntry(
      version: json['version'] is String ? json['version'] as String : '',
      title: json['title'] is String ? json['title'] as String : '',
      source: json['source'] is String ? json['source'] as String : '',
      published: json['published'] is String
          ? json['published'] as String
          : null,
      tag: json['tag'] is String ? json['tag'] as String : null,
      points: points,
    );
  }
}

const releaseHistory = <ReleaseEntry>[
  ReleaseEntry(
    version: '1.1.4',
    title: '网络质量探测 1.1.4',
    source:
        '仓库 docs/release-notes/1.1.4.md。署名言灸。这一版的 Git 标签要等发布时才有，这里写的是即将发布的内容。',
    points: [
      '设置里可以选择更新源，默认是 YanJiu Git，也可以改成 GitHub。检查和下载都先用选中的源，连不上再试另一个，结果里会写明这次实际用的是哪一个。',
      '「更新历史」会读取所选源的发布列表，包括比当前安装更新的版本，并在本机留一份。网络失败时用上次保存的列表，没有保存过再用安装包里的说明，并标明可能不是最新。已经发出的 1.1.2 和 1.1.3 没有这份同步。',
      '表单里被省略号截断的提示可以点开看全文，再点一次收回。本来就显示得下的短句不用点。',
      'HTTP 目标填完整网址，或只写主机名、IP。只写主机名时按 http 和端口 80，不再单独填端口。超时默认 5000 毫秒。本机找不到探测引擎时会立刻说明，并建议改用远程节点。',
      '桌面自更新认得已经发布的 linux-x64、windows-x64 文件名，也仍然接受 amd64、x86_64、aarch64。名字里带 server 或 reflector 的包不会被选中。1.1.3 的桌面更新器认不出 x64，升到 1.1.4 仍要手动安装。',
    ],
  ),
  ReleaseEntry(
    version: '1.1.3',
    title: '网络质量探测 1.1.3',
    published: '2026-11-21',
    source: 'Git 标签 v1.1.3，以及 GitHub Release「网络质量探测 1.1.3」（发布于 2026-11-21）。',
    points: [
      '可以自动检查更新，也能在设置里关掉。先问 GitHub，连不上再用备用 Git。1.1.2 没有这个功能，升到 1.1.3 仍要手动安装。从这一版起，新版本才会自己下载并覆盖安装。',
      'Windows 和 Linux 覆盖进现有安装目录。设置、已保存的节点、口令和探测历史仍在应用自己的数据目录里，不会被安装包清掉。',
      '点「开始探测」会记下目标、端口和类型。目标框旁边可以打开最近的记录，点一条填回表单，也可以单条删除或全部清除。这里不保存节点口令、中心口令、Cookie 和请求体。',
      '设置里可以分别关闭 IPv4 或 IPv6。两个都关、或填写了已关闭的那种地址时，不会开始。远程节点会收到同样的选择。',
      '新增 HTTP 探测，包含 HTTP/3。可以指定方法、请求头、请求体、跳转次数，以及 curl --resolve 那种指定解析。4xx 和 5xx 显示状态码，不叫丢包。',
      '同一个程序可以当中心。客户端用「一键添加服务器」填中心地址、账号和口令，一次加入这个口令能用的全部节点。保密节点只显示中心给的名称，探测由中心转发，本机不保存地址。',
    ],
  ),
  ReleaseEntry(
    version: '1.1.2',
    title: '网络质量探测 1.1.2',
    published: '2026-11-20',
    source: 'Git 标签 v1.1.2，以及 GitHub Release「网络质量探测 1.1.2」（发布于 2026-11-20）。',
    points: [
      '可以修改已有远程节点的名称、控制地址和口令。节点编号和当前选择保持不变。口令留空表示不改，界面不显示已经保存的口令。',
      '端口框标明当前类型的默认端口。合作反射 TCP 是 19090，UDP 是 19091。只有端口仍是上一种类型的默认值，或端口是空的，切换类型才会自动更换。',
      '本机和远程节点都显示实际连通或实际发包的地址，以及 IPv4 / IPv6。旧节点如果没有上报地址，会写明未报告，不会把域名解析的第一个地址当成已经使用的地址。',
      '选址阶段失败的候选（例如 IPv6 没有应答后改用 IPv4）不再计入正式丢包，并单独说明回退。选定地址之后的失败仍然计入。全部候选都失败时显示失败，不会显示 0% 成功。',
      '结果给出已发送、已收到、超时、比率、当前/最小/平均/中位/P95/最大延迟、抖动和用时。某种探测没有测量的量会标成不适用或 —。',
      '手动停止后保留曲线，并给出开始、结束、用时、目标、来源、实际地址和最终指标。停止时还没完成的请求不计入丢包。',
      '点曲线可以钉住该时刻的数值，松手后仍然保留；再点另一点会更换。新的一次探测，或该点滚出窗口后，不会沿用过期选择。',
      '新增「指标说明」。',
    ],
  ),
  ReleaseEntry(
    version: '1.1.1',
    title: '网络质量探测 1.1.1',
    published: '2026-11-09',
    source: 'Git 标签 v1.1.1，以及 GitHub Release「网络质量探测 1.1.1」（发布于 2026-11-09，之后补过桌面和节点压缩包）。',
    points: [
      '本机 UDP 会把解析出的地址逐个试过，停在第一个真正有应答的地址上。',
      '还没有地址应答时，一次超时就换下一个。已经有应答之后，要连续 3 次没有应答才换。',
      '结果里显示当时实际在用的地址。地址落在 198.18.0.0/15 时，会提示这是 VPN 假地址。',
      '发布物包含 Android APK（arm64-v8a 与 armeabi-v7a，versionName 1.1.1，versionCode 分别为 2004 和 1004）、Linux 与 Windows 桌面客户端，以及 Linux amd64、Linux arm64、Windows amd64 的检测节点包。',
      '标签 v1.1.1 没有因为后来补上的桌面和节点压缩包而移动。',
    ],
  ),
];

const releaseHistoryNote =
    '仓库里公开的版本标签有 v1.1.1、v1.1.2 和 v1.1.3。1.1.4 的标签要等发布时才有。1.1.1 的发布说明提到过更早的发包行为，但没有单独的标签或 Release，所以这里不写成另一个版本。';

/// Already shipped installers cannot grow this screen. The sentence stays
/// visible so the app does not imply that 1.1.2 or 1.1.3 already sync notes.
const onlineHistoryLimitNote =
    '已经发布的 1.1.2 和 1.1.3 安装包没有在线更新历史。那些版本不会自己同步以后的发布说明，需要先安装包含这个功能的版本。';
