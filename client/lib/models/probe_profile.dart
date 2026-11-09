class ProbeProfile {
  const ProbeProfile({
    required this.id,
    required this.label,
    required this.port,
    required this.blurb,
    required this.rateLabel,
  });

  final String id;
  final String label;
  final int port;
  final String blurb;

  /// Name of the chart that is honest for this profile.
  final String rateLabel;

  static const nqTcp = ProbeProfile(
    id: 'nq-tcp',
    label: '合作反射 TCP',
    port: 19090,
    blurb: '和 NetQuality 反射器保持一条 TCP 长连接，按回显计算往返时间。超时只表示探测没有应答，不是物理丢包。',
    rateLabel: '探测无应答',
  );
  static const nqUdp = ProbeProfile(
    id: 'nq-udp',
    label: '合作反射 UDP',
    port: 19091,
    blurb: '向 NetQuality 反射器发 UDP，收到对应序号的回显才算成功。',
    rateLabel: '探测无应答',
  );
  static const tcpConnect = ProbeProfile(
    id: 'tcp-connect',
    label: '普通 TCP 连通',
    port: 80,
    blurb: '只测量能否连上以及连接耗时，不发送自定义探测帧。',
    rateLabel: '失败率',
  );
  static const udpGeneric = ProbeProfile(
    id: 'udp-generic',
    label: '普通 UDP',
    port: 9,
    blurb: '发出 UDP 后如果没有协议应答，记为无应答/未知，不能当成丢包。',
    rateLabel: '无应答（未知）',
  );
  static const dns = ProbeProfile(
    id: 'dns',
    label: 'DNS',
    port: 53,
    blurb: '发送标准 DNS 查询，序号和应答标志都对上才算成功。',
    rateLabel: '无应答（未知）',
  );
  static const minecraftJava = ProbeProfile(
    id: 'minecraft-java',
    label: 'Minecraft Java',
    port: 25565,
    blurb: '按 Java 版状态握手读取 MOTD，再用 ping/pong 计算往返时间。',
    rateLabel: '失败率',
  );
  static const minecraftBedrock = ProbeProfile(
    id: 'minecraft-bedrock',
    label: 'Minecraft 基岩版',
    port: 19132,
    blurb: '发送 RakNet Unconnected Ping，校验 magic 和原时间戳。',
    rateLabel: '无应答（未知）',
  );
  static const customUdp = ProbeProfile(
    id: 'custom-udp',
    label: '自定义 UDP',
    port: 19132,
    blurb: '发送你填写的十六进制载荷。可以要求响应以前若干字节开头。',
    rateLabel: '无应答（未知）',
  );

  static const all = <ProbeProfile>[
    nqTcp,
    nqUdp,
    tcpConnect,
    udpGeneric,
    dns,
    minecraftJava,
    minecraftBedrock,
    customUdp,
  ];

  static ProbeProfile byId(String id) {
    for (final profile in all) {
      if (profile.id == id) {
        return profile;
      }
    }
    return nqTcp;
  }

  bool get needsPacketSize =>
      id == 'nq-tcp' || id == 'nq-udp' || id == 'udp-generic';

  bool get needsEchoToken => id == 'nq-tcp' || id == 'nq-udp';

  bool get isNq => needsEchoToken;
}

String rateLabelFor(String profileId) => ProbeProfile.byId(profileId).rateLabel;
