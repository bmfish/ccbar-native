# V2EX · 分享创造

建议节点：分享创造
建议标题：CCBar：把 Claude Code / Codex / Trae / GLM 的用量和积分放进菜单栏

---

最近同时在用 Claude Code、Codex 和 Trae，还有一个跑 GLM 的 ZCode。用量散在几个工具里，Trae 的积分还得单独开网页看，于是写了个 macOS 菜单栏小工具 CCBar，把这几个来源汇到一个地方。

它能做什么：

- 菜单栏直接显示今日 token，按用量阈值变色，默认 30 秒刷新
- 点开是今日卡片：请求数、缓存命中率、工时、积分，以及昨日 / 近 7 天 / 近 30 天 / 历史总量
- 洞察中心：30 天走势、90 天热力图、模型编年史、渠道构成、费用排行、月度预算
- Trae 积分单独一页：今日积分、余额、按日均消耗还能用几天
- 数据留在本机：cc-switch 和 ZCode 的库只读 attach，历史每天补进自己的 SQLite，今天实时查询
- macOS 13+，Universal；另外有 Windows 托盘版，单文件 exe
- MIT 开源，无账号、无遥测

目前只接了 cc-switch、ZCode、Trae 三个源，没有云同步。macOS 安装包还没有做 Apple 公证，首次打开需要右键选择“打开”，或者在终端执行：

```
xattr -dr com.apple.quarantine /Applications/CCBar.app
```

官网（截图和下载）：https://ccbar-jjawpfzj0an.qoder.website
源码：https://github.com/bmfish/ccbar-native

做这个主要是给自己用，顺手把觉得有用的部分做全了。欢迎试用后提意见，尤其是统计口径、Trae 同步和安装体验这几块。
