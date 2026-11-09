# 在 Linux 服务器上安装反射服务

反射服务是一个小程序。它不做账号、不存数据，只把探测包原样送回去。请装在你自己的机器上。

下面假设系统是 Ubuntu 或 Debian，已经能用 `sudo`。其他发行版把安装 Go 的那一步换成自己的包管理器即可。

## 1. 安装 Go

需要 Go 1.22 或更新的版本。

```bash
sudo apt update
sudo apt install -y golang-go
go version
```

如果发行版自带的 Go 太旧，到 [https://go.dev/dl/](https://go.dev/dl/) 下载官方包。

## 2. 编译并前台运行（先确认能通）

把本仓库的 `server` 目录拷到服务器，例如 `/opt/netquality/server`。在该目录执行：

```bash
cd /opt/netquality/server
go build -o netquality-reflector .
./netquality-reflector
```

默认监听：

- TCP `0.0.0.0:19090`
- UDP `0.0.0.0:19091`

看到两行 `listening` 就说明起来了。另开一个终端可以看端口：

```bash
ss -ltnp | grep 19090
ss -lunp | grep 19091
```

用 `Ctrl+C` 停止。确认客户端能连上之后，再做成开机自启。

常用参数：

```bash
./netquality-reflector -bind 0.0.0.0 -tcp-port 19090 -udp-port 19091
./netquality-reflector -tcp-port 0          # 只开 UDP
./netquality-reflector -token '一段口令'     # 口令最长 32 字节
./netquality-reflector -h
```

也可以用环境变量：`NQ_BIND`、`NQ_TCP_PORT`、`NQ_UDP_PORT`、`NQ_TOKEN`（回显口令）、`NQ_MODE`、`NQ_CONTROL_ADDR`、`NQ_NODE_TOKEN`（节点口令）、`NQ_ALLOW_PRIVATE`、`NQ_TLS_CERT`、`NQ_TLS_KEY`。

## 3. 做成系统服务

```bash
cd /opt/netquality/server
go build -o netquality-reflector .
sudo install -m 0755 netquality-reflector /usr/local/bin/netquality-reflector
sudo cp deploy/netquality-reflector.service /etc/systemd/system/netquality-reflector.service
sudo systemctl daemon-reload
sudo systemctl enable --now netquality-reflector
sudo systemctl status netquality-reflector
```

日志：

```bash
journalctl -u netquality-reflector -f
```

大约每分钟会打一行统计：收到多少请求、回了多少、拒绝了多少。

要加口令时，编辑服务文件，去掉 `NQ_TOKEN` 那一行的注释并写成你自己的口令，然后：

```bash
sudo systemctl daemon-reload
sudo systemctl restart netquality-reflector
```

App 里的「口令」必须和这里完全一致。口令是明文写在探测包里的，只能挡住无关的随机访问，不能当密码学上的加密。

## 4. 放行防火墙

只放行你实际使用的端口。

ufw：

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

如果服务器在阿里云、腾讯云、AWS 或其他云上，安全组里也要放行同样的端口。只放系统防火墙、不放安全组，外网还是连不上。

不需要的协议就不要放行。只想测 UDP 时，可以让服务以 `-tcp-port 0` 启动，并且只开放 UDP。

## 5. 让这台机器替手机去测别的目标

反射器只把自己收到的探测包送回去。如果手机要测的是别的业务端口，例如游戏服务器，应让这台机器作为节点去发包。手机只下指令、看结果。

同一个程序有三种模式：

```bash
./netquality-reflector -mode reflector
./netquality-reflector -mode node -control-addr 127.0.0.1:8443
./netquality-reflector -mode both -bind 0.0.0.0 -tcp-port 19090 -udp-port 19091 -control-addr 127.0.0.1:8443
```

`both` 会同时提供反射和节点。控制地址默认只听本机，这样不会一启动就把探测能力暴露到公网。

### 公开节点

不设置 `-node-token` 就是公开节点。谁能访问控制端口，谁就能在上限内发起探测。程序会在日志里写一行警告。上限包括同时任务数、单次时长、最小间隔、每秒次数和带宽。这不是开放代理：默认不去拨本机、内网、链路本地和云元数据。

```bash
./netquality-reflector -mode node -control-addr 127.0.0.1:8443
```

### 私有节点

设置了节点口令以后，创建任务、看结果、看流、停止任务都会先校验。口令不对，不会向目标发包。把下面的占位文字换成你自己的口令，不要把真实口令发到聊天或提交到仓库。

```bash
./netquality-reflector -mode node -control-addr 127.0.0.1:8443 -node-token '换成你自己的节点口令'
```

`-token` 是另一回事，它写进反射帧，只在别人来连你的 19090/19091 时使用。App 里对应「目标回显口令」。节点口令对应「管理节点」里的那一栏。

要开机启动节点，可以用 `deploy/netquality-node.service`。编辑里面的环境变量注释，再：

```bash
sudo cp deploy/netquality-node.service /etc/systemd/system/netquality-node.service
sudo systemctl daemon-reload
sudo systemctl enable --now netquality-node
```

故意测机房局域网时加 `-allow-private`。云厂商的元数据地址即使加了这个参数也不会放行。

### HTTPS

控制通道会带节点口令，不要直接把明文 HTTP 暴露到公网。两种做法：

用程序自己的证书：

```bash
./netquality-reflector -mode node -control-addr 0.0.0.0:8443 -tls-cert /etc/netquality/fullchain.pem -tls-key /etc/netquality/privkey.pem -node-token '换成你自己的节点口令'
```

或让 Caddy / nginx 终止 HTTPS，再反代到 `127.0.0.1:8443`。Caddy 的站点可以写成：

```text
probe.example {
    reverse_proxy 127.0.0.1:8443
}
```

防火墙和安全组只放行 443，不要把 8443 直接敞开。反射端口 19090/19091 仍然是普通 TCP/UDP，和这个 HTTPS 控制端口是分开的。

## 6. 在 App 里填写

本机直接测反射器：

- 来源：本机
- 目标：服务器的公网 IP 或域名，不要在手机上填 `127.0.0.1`
- 类型：合作反射 TCP 或 UDP
- 端口：`19090` 或 `19091`
- 目标回显口令：和服务器的 `-token` 相同；服务器没设就留空

让节点去测：

1. 来源选「远程节点」，点「管理节点」。
2. 地址填 `https://你的域名`（或你实际反代后的地址）。不要把口令写在地址里。
3. 节点口令：私有节点填写，公开节点留空。可以点「检查」，看到「公开」或「需要口令」。
4. 目标地址、端口、类型另填。例如 Minecraft Java 用游戏域名和 `25565`。
5. 点「开始探测」。延迟是节点到目标的时间。停止后节点会结束任务。

## 本机演示补充

在自己的电脑上同时开反射和节点，并允许它探测本机：

```bash
./netquality-reflector -mode both -bind 127.0.0.1 -tcp-port 19090 -udp-port 19091 -control-addr 127.0.0.1:8443 -allow-private
```

App 里添加节点 `http://127.0.0.1:8443`，口令留空，目标填 `127.0.0.1` 和对应端口。这只适合确认功能，不代表公网质量。

## 只开反射器的本机演示

不想先买服务器时，在自己的电脑上运行同一个程序即可：

```bash
cd server
go build -o netquality-reflector .
./netquality-reflector
```

App 保持默认的 `127.0.0.1`，直接点开始。这只能证明程序工作正常。延迟会接近 0，不代表宽带或移动网络的质量。
