// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import 'quality_charts.dart';

class MetricGuidePage extends StatelessWidget {
  const MetricGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Scaffold(
      appBar: AppBar(
        title: const Text('指标说明'),
        backgroundColor: const Color(0xFFF3F1EC),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                wide ? 24 : 12,
                8,
                wide ? 24 : 12,
                28,
              ),
              children: const [
                _Section(
                  title: '这些数字从哪来',
                  body: '曲线和百分比只来自已经完成、并且计入正式结果的探测。还在途中的请求不会画成 100%，停止时被取消的请求也不算丢包。没有内置样本。',
                ),
                _Section(
                  title: '已发送、已收到、超时',
                  body: '已发送是计入正式结果的次数。已收到是其中成功的次数：合作反射收到了对上序号的回显，普通 TCP 是连上了，其他类型是收到了符合协议的应答。\n\n合作反射的「超时」只计已经把探测帧写出去、但超时前没有对上序号的次数。还没连上、连接被拒绝，不算进这个超时，也不算进探测无应答。\n\n普通 UDP、DNS、自定义 UDP 和基岩版如果根本没有协议应答，记为「无应答」，超时这一项显示不适用。收到了包但内容不对，记为协议错误。UDP 沉默不能当成已经证实的丢包：对端可以合法地不回答。',
                ),
                _Section(
                  title: '探测无应答、失败率、无应答',
                  body: '合作反射 TCP / UDP：探测无应答 = 超时 ÷（超时 + 成功）× 100%。分母只含已经写出的回显尝试。分母为 0 时显示 —，而不是 0%。TCP 会重传，所以这不是网卡上的物理丢包。\n\n普通 TCP 和 Minecraft Java：失败率 = 未成功的正式尝试 ÷ 已完成的正式尝试 × 100%。这里没有丢包百分比。\n\n其余 UDP 类探测：无应答 = 无应答次数 ÷ 已完成次数 × 100%。它回答的是「没有看到协议应答」，不是「丢了多少包」。',
                ),
                _Section(
                  title: '延迟、中位数、P95 和抖动',
                  body: '延迟只来自成功的样本，单位是毫秒。当前延迟是最近一次成功的往返时间。最小、平均、最大都是这些成功样本的最小、算术平均和最大。\n\n中位数：把成功样本从小到大排列。奇数个取中间那个；偶数个取中间两个的平均。\n\nP95 用最近秩：秩 = ceil(0.95 × 次数)，用整数 (95 × 次数 + 99) / 100 计算，从 1 开始，取排序后这个位置的值。次数为 1 时，P95 就是那一次。\n\n抖动按 RFC 3550：D 是相邻两次成功往返时间之差，J = J + (|D| − J) / 16。第一次成功时 J 为 0；没有成功时显示 —。远程探测的往返时间在节点上用单调时钟量好再传回来，不包含手机到节点的控制通道耗时。\n\n旧版本节点不会上报最小、平均、中位、P95 和最大。这时这些格子显示「节点未提供」，当前延迟和抖动仍用它原来上报的值。',
                ),
                _Section(
                  title: '用时',
                  body: '用时是这次会话从按下开始到停止（或到当前）的墙钟时间。它不是各次往返时间相加，也不包括节点在创建任务之前花掉的时间。',
                ),
                _Section(
                  title: '选址失败和正式丢包',
                  body: '一个域名可能同时有 IPv6 和 IPv4。程序会先试一个地址。还没有任何地址应答时，连不上或没有应答会换下一个。这种只为挑选地址而失败的尝试，如果后面有地址成功，就不计入已发送、超时和丢包，界面单独写明回退了哪个地址。\n\n一旦某个地址已经应答，之后对它的超时或失败都算正式结果，不会因为后来又换地址而被抹掉。只有一个地址时，失败从一开始就算正式结果。\n\n如果每一个候选都失败，这些失败会计入正式结果。界面显示失败或 100% 的无应答/失败率，不会显示 0% 成功。\n\n1.1.1 的远程节点还不会做这层区分，它的统计可能仍把第一次选址失败算进去。要分开看，节点也需要 1.1.2。',
                ),
                _Section(
                  title: '实际地址和 IPv6 回退',
                  body: '「实际地址」是这次真正连通或真正发包的 IP，并注明 IPv4 或 IPv6。「解析到」只是域名解析的结果，不会被说成已经在用的地址。\n\n正在尝试、还没有正式结果时，会标明正在尝试，而不是写成已经发往。远程节点如果没有在结果里带上地址（旧版本就是这样），界面写「节点没有报告实际使用的地址」，不会在手机上另做一次解析来冒充。\n\n地址落在 198.18.0.0/15 时，会提示这是 VPN 假地址，只有这个 VPN 开着时才能用。',
                ),
                _Section(
                  title: 'IPv4 和 IPv6',
                  body: '设置里有两个开关，默认都开着。解析出多个地址以后，只向打开的地址族发包。只开一个，就只用那一个。两个都关掉时不会开始，并说明原因。目标本身就是被关掉的那种地址时，也不会开始。\n\n远程任务会带上同样的选择，节点不会改用另一个地址族。结果里的实际地址和地址族，仍然是这一次真正用到的那个。',
                ),
                _Section(
                  title: 'HTTP',
                  body: 'HTTP 探测记下 DNS、连接、TLS、首字节和总时间，以及状态码、最终地址和实际用到的 HTTP 版本（1.1、2 或 3）。曲线上的延迟是总时间。已经收到的响应算成功，4xx 和 5xx 只显示状态码，不叫丢包，也不算进失败率。连不上或强制的版本不被支持，才算失败。\n\n默认先试 HTTP/2，不行再降到 1.1。选了「仅 HTTP/1.1」「仅 HTTP/2」或「仅 HTTP/3」时，服务器不支持就失败，不会悄悄换一种。指定解析只改连接走的地址，Host 和 SNI 仍用目标网址，用来看 CDN。它不是把 1.1.1.1 当成 DNS 服务器。\n\nHTTP/3 的连接和 TLS 是同一次 QUIC 握手，这两项时间相同。本机探测和节点用的是同一个 Go 引擎。桌面端需要把 netquality-reflector 放在程序旁边，或设置 NQ_PROBE_HELPER。Android 上如果系统不允许从应用目录启动这个程序，本机 HTTP 会说明缺引擎；远程节点不受影响。',
                ),
                _Section(
                  title: '停止以后',
                  body: '点停止会保留曲线，并给出开始、结束、用时、目标、类型、来源、实际地址和同一套最终指标。正在进行、因为停止而被取消的请求不计入丢包。重新开始会换一次新的会话，旧曲线不会混进来。\n\n点曲线上的一点可以钉住该时刻的延迟和比率，松手后仍然留着。再点另一点会换。新会话或这个点滚出窗口后，选择会被清掉，不会跳到别的点上。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
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
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(height: 1.45, color: ink)),
          ],
        ),
      ),
    );
  }
}
