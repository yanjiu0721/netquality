# 网络质量探测 · 检测节点

这是装在电脑或服务器上的小程序。手机上的 App 负责看结果，真正收发包的是这里。

它能做两件事，也可以一起做：

- **反射**：把探测包原样送回去。手机直接测到这台机器的延迟。
- **节点**：手机只下指令。这台机器替手机去测别的地址，例如游戏服务器。

压缩包里已经有一份能直接用的 `.env`，默认端口和以前一样：TCP `19090`、UDP `19091`。不改也能用。

## 三步启动

1. 解压整个压缩包，不要只把程序单独拷走。`.env` 要和程序放在同一个文件夹。
2. 用记事本（Windows）或任意文本编辑器打开 `.env`。每一项上面都有中文注释。改完保存。
3. 运行：
   - Windows：双击 `start.bat`，不要关那个黑窗口。
   - Linux：在解压出来的文件夹里打开终端，执行 `./netquality-reflector`。

程序启动后会打一行「生效配置」。口令只显示「已设置」或「未设置」，不会把口令本身打出来。看到 `listening` 就说明端口已经打开。

用 `Ctrl+C` 停止。Windows 上关闭黑窗口也会停。

## 配置写在哪里

程序启动时会读配置，优先级从高到低是：

1. 命令行参数，例如 `-tcp-port 19090`
2. 系统环境变量，例如 `NQ_TCP_PORT`
3. `.env` 文件
4. 程序内置的默认值

`.env` 会找两个地方：程序所在的文件夹，以及你当前打开的文件夹。两个路径不一样时，当前文件夹里的 `.env` 优先。文件不存在不算错误。

也可以指定别的文件：`./netquality-reflector -env /etc/netquality/.env`。这个文件必须存在，否则程序会退出。

`.env.example` 是同一份说明，给别人抄着用。真正生效的是 `.env`。

改完 `.env` 要重新运行程序。已经在跑的那一次不会自己重读。

## 每一项是什么

| 配置项 | 默认 | 作用 |
| --- | --- | --- |
| `NQ_BIND` | `0.0.0.0` | 反射听哪块网卡。`0.0.0.0` 是全部网卡，`127.0.0.1` 是只给本机 |
| `NQ_TCP_PORT` | `19090` | TCP 反射端口。`0` 关闭 TCP |
| `NQ_UDP_PORT` | `19091` | UDP 反射端口。`0` 关闭 UDP |
| `NQ_TOKEN` | 空 | 回显口令。空表示不检查。最长 32 字节。对应手机里的「目标回显口令」 |
| `NQ_MODE` | `reflector` | `reflector` 只反射，`node` 只做节点，`both` 两个一起 |
| `NQ_CONTROL_ADDR` | `127.0.0.1:8443` | 节点控制地址。默认只有本机能连 |
| `NQ_NODE_TOKEN` | 空 | 节点口令。空表示公开节点。对应手机「管理节点」里的口令 |
| `NQ_ALLOW_PRIVATE` | `false` | `true` 才允许去测本机和局域网。云元数据地址始终禁止 |
| `NQ_ALLOW_NETS` | 空 | 额外允许的网段，逗号分隔，例如 `10.1.2.0/24` |
| `NQ_TLS_CERT` | 空 | 控制端口的证书。和私钥要同时填 |
| `NQ_TLS_KEY` | 空 | 控制端口的私钥 |
| `NQ_VERBOSE` | `false` | `true` 时每个包都写日志 |

回显口令 `NQ_TOKEN` 和节点口令 `NQ_NODE_TOKEN` 不是同一个。回显口令写在探测包里，只能挡住随便扫过来的访问，不能当加密。设了口令以后，把 `.env` 的权限收紧，别让别人读到：

```bash
chmod 600 .env
```

## 在手机里怎么填

测这台机器自己（反射）：

- 来源选「本机」
- 目标填这台机器的 IP，不要在手机上填 `127.0.0.1`
- 类型选「合作反射 TCP」或「合作反射 UDP」
- 端口填 `19090` 或 `19091`（和 `.env` 里一致）
- 目标回显口令和 `NQ_TOKEN` 一致；`.env` 里留空，手机也留空

让这台机器替手机去测别的地址：

1. `.env` 里把 `NQ_MODE` 改成 `node` 或 `both`，保存后重新运行。
2. 手机来源选「远程节点」，点「管理节点」。
3. 地址要能从手机访问到。`.env` 默认的 `127.0.0.1:8443` 只有服务器自己能用。给手机用时改成 `0.0.0.0:8443`，手机里填 `http://服务器IP:8443`。放到公网时请用 HTTPS，不要把明文控制端口直接敞开。
4. 节点口令和 `NQ_NODE_TOKEN` 一致。留空就是公开节点。

## 防火墙要放行的端口

只放行你真正用的端口。

- 反射 TCP：`.env` 里的 `NQ_TCP_PORT`，默认 `19090/tcp`
- 反射 UDP：`.env` 里的 `NQ_UDP_PORT`，默认 `19091/udp`
- 节点控制：只有控制地址不是 `127.0.0.1` 时才需要。默认 `8443/tcp`

Ubuntu 的 ufw：

```bash
sudo ufw allow 19090/tcp
sudo ufw allow 19091/udp
sudo ufw status
```

firewalld：

```bash
sudo firewall-cmd --permanent --add-port=19090/tcp
sudo firewall-cmd --permanent --add-port=19091/udp
sudo firewall-cmd --reload
```

云服务器还要在安全组里放行同样的端口。只改系统防火墙、不改安全组，外面还是连不上。

## Linux 开机自启

下面假设压缩包解压到 `/opt/netquality`，里面能看到 `netquality-reflector`、`.env` 和 `netquality.service`。

```bash
sudo mkdir -p /opt/netquality
sudo tar -C /opt/netquality --strip-components=1 -xzf netquality-server-1.1.1-linux-amd64.tar.gz
sudo chmod 755 /opt/netquality/netquality-reflector
sudo cp /opt/netquality/netquality.service /etc/systemd/system/netquality.service
sudo systemctl daemon-reload
sudo systemctl enable --now netquality
sudo systemctl status netquality
```

ARM 机器用文件名里带 `linux-arm64` 的那个压缩包，解压命令同样，只是文件名不同。

以后只改 `/opt/netquality/.env`，然后：

```bash
sudo systemctl restart netquality
```

看日志：

```bash
journalctl -u netquality -f
```

大约每分钟会有一行统计：收到多少、回了多少、拒绝了多少。

`netquality.service` 的内容就是：

```ini
[Unit]
Description=网络质量探测节点
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/netquality
ExecStart=/opt/netquality/netquality-reflector
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

不要在服务文件里再写端口。端口以 `.env` 为准。如果服务文件里写了环境变量，那个值会盖过 `.env`。

仓库里还有两份示例：`deploy/netquality-reflector.service` 只按 `.env` 运行；`deploy/netquality-node.service` 额外固定 `NQ_MODE=both`。两份不要同时启用，否则会抢同一个端口。
