# 网络质量探测 · Linux 桌面客户端

这是 1.1.1 的 Linux 64 位桌面程序，解压后可以直接运行。不需要再安装 Flutter。

## 先安装系统库

Ubuntu 或 Debian：

```bash
sudo apt update
sudo apt install -y libgtk-3-0 libblkid1 liblzma5
```

其他发行版安装同样的 GTK 3 运行库即可。

## 运行

在解压出来的文件夹里执行：

```bash
./netquality
```

不要把 `netquality` 单独拷走。它需要旁边的 `lib` 和 `data` 目录。

第一次打开如果窗口一闪就关，把上面的系统库装上再试。

## 和手机版的关系

用法和手机相同：选「本机」直接测，或选「远程节点」让你自己的 Linux 节点去测。节点程序是另外的压缩包（文件名以 `netquality-server` 开头），不在这个包里。
