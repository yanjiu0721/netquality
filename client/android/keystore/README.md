# Android 签名

1.1.3 以及以后的 debug 和 release 都使用本目录的 `debug.keystore`。

- 别名 `androiddebugkey`
- storepass 和 keypass 都是 `android`
- 证书 SHA-256 必须是 `8bdbe4a3b25d611688d3e6f65524c87868217cdffd69d541eadd0916b7909c03`

这是已经发布的 1.1.3 安装包用的那一把。不要另建密钥，也不要换成应用商店证书，否则已安装的 1.1.3 无法覆盖升级。构建脚本在文件缺失时会直接失败。
