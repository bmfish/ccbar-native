# cc-switch 互推 issue 文案

> 提交地址：https://github.com/farion1231/cc-switch/issues
> 建议分类：讨论 / 生态分享。语气是"生态补充"而不是"打广告"，发之前把数字换成当天的。

---

**标题**：生态分享：CCBar —— 把 cc-switch 记录的用量放进菜单栏常驻显示（只读，已适配）

**正文**：

你好，我是 cc-switch 的重度用户（多供应商切换 + 代理基本常开）。用量数据 cc-switch 都记在本地库里，但日常总想"余光扫一眼"而不是打开面板，所以就写了个配套的开源小工具 **CCBar**，跑了一段时间觉得挺搭，来分享一下：

- macOS 菜单栏 / Windows 托盘常驻今日 token 用量，按阈值变色 + 预警通知 + 里程碑提醒
- 数据来源就是 cc-switch 的 `proxy_request_logs` 和 `usage_daily_rollups`：历史每天增量同步到 CCBar 自己的库，今日实时查询——**对 cc-switch.db 全程只读 ATTACH，不写任何表**（之前的旧版本曾往库里写过备份表，v1.1.0 起已移除）
- 另外接了 ZCode（按它官方口径 input+output，可和 ZCode 用量页直接对账），数据源是插件式的，后续打算支持更多 agent
- 完全本地运行，不上报数据，开源（macOS Swift 原生 / Windows Python）

- macOS：https://github.com/bmfish/ccbar-native
- Windows：https://github.com/bmfish/ccbar-win

两个请求：

1. 如果你觉得这个方向 OK，能否在 README 的相关项目 / 生态板块加个链接？我这边也会在 README 里把 cc-switch 作为唯一推荐的 Claude Code 代理数据源
2. 如果未来 `proxy_request_logs` / `usage_daily_rollups` 的 schema 有变动，希望能在这个 issue 里知会一声，我会同步适配（目前 v1.1.0 适配的是当前 schema，含 request_count 聚合口径）

有问题或者觉得哪里不合适，直接说，我马上调。
