# 客户端

Flutter 应用，支持 Linux、Windows 桌面和 Android。用法、节点安装和协议说明见仓库根目录的 [README.md](../README.md)。

```bash
flutter pub get
flutter run -d linux
```

默认用本机去测 `127.0.0.1` 的合作反射 TCP `19090`。先在 `../server` 里启动反射服务，再点「开始探测」。要让另一台机器代测时，把来源改成「远程节点」。
