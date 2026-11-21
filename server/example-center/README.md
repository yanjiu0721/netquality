# 中心配置示例

这里的口令、密码和密钥都是占位，只能用来在本机看目录长什么样。不要拿到公网上去用。

目录：

- `groups.json`：用户组。一个中心可以有很多组。
- `tokens.json`：只保存口令和密码的 `sha256:` 哈希，不保存原文。每一条口令只属于一个组。
- `servers/*.json`：中心分配的显示名、节点控制地址、哪些组可以用、是否保密。节点的长期口令只写在这里，发给中心用来转发，不会交给客户端。
- `center.key`：签发短期凭证的密钥。节点上的 `NQ_CENTER_KEY` 要和它相同，`NQ_SERVER_ID` 要和对应服务器文件的 `id` 相同。

示例账号 `lab`，口令原文 `example-token`，密码原文 `example-password`。哈希用：

```bash
printf '%s' 'example-token' | ./netquality-reflector -hash-secret
```

`实验室节点` 不是保密的，客户端能看到地址，并用短期凭证直接连接。`保密节点` 的地址只留在这份配置里，目录接口不会把它交出去，探测由中心转发。
