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
  });

  final String version;
  final String title;
  final String source;
  final String? published;
  final List<String> points;
}

const releaseHistory = <ReleaseEntry>[
  ReleaseEntry(
    version: '1.1.2',
    title: '网络质量探测 1.1.2',
    source: '仓库 docs/release-notes/1.1.2.md。这一版的 Git 标签要等发布时才有，这里写的是即将发布的内容。',
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
    '仓库里目前公开的版本标签只有 v1.1.1。1.1.1 的发布说明提到过更早的发包行为，但没有单独的标签或 Release，所以这里不写成另一个版本。';
