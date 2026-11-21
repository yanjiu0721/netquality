# 客户端

Flutter 应用，支持 Linux、Windows 桌面和 Android。用法、节点安装和协议说明见仓库根目录的 [README.md](../README.md)。

```bash
flutter pub get
flutter run -d linux
```

默认用本机去测 `127.0.0.1` 的合作反射 TCP `19090`。合作反射 UDP 默认 `19091`。先在 `../server` 里启动反射服务，再点「开始探测」。要让另一台机器代测时，把来源改成「远程节点」。当前版本是 1.1.3。本机 HTTP 探测需要旁边有 `netquality-reflector`，或设置 `NQ_PROBE_HELPER`。指标怎么读、这一版改了什么，在应用里的「指标说明」和「更新历史」。
