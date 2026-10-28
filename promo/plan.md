# CCBar 推广执行计划

基准日期：2026-10-25
当前版本：v1.9.20（macOS / Windows 已对齐）

## 1. 定位与一句话

**定位**：同时用多个 AI CLI、并且在意 Trae 积分与本地隐私的开发者。

**一句话**：把 Claude Code、Codex、GLM 和 Trae 的 token、积分与花费，收进 macOS 菜单栏和 Windows 托盘；数据只留在本机。

**差异化**（按重要度）：

1. 同时覆盖 cc-switch / ZCode / Trae，且把 Trae 积分与「还能用几天」做成独立页面
2. 本地优先：源库只读、自建 SQLite、无账号、无遥测
3. 不只是今天：90 天热力图、模型编年史、费用排行、月度预算、周报/战报分享
4. 双平台 + MIT 开源

不要这样讲：不要用「最好用」「最强」；不要把 cc-switch 的能力说成 CCBar 自己抓包；不要暗示有云同步或多端同步。

## 2. 指标基线（2026-10-25 抓取）

| 指标 | bmfish/ccbar-native | bmfish/ccbar-win |
|---|---|---|
| Stars | 1 | 0 |
| Forks / watchers | 0 / 1 | 0 / 0 |
| 近 14 天仓库访问 | 11 次 / 2 唯一访客 | 0 |
| 全版本 DMG 下载 | 4 | — |
| 全版本 exe 下载 | — | 4 |
| v1.9.20 发布当天 | 1 次 DMG | 2 次 exe |
| Open issues | 0 | 0 |

结论：目前基本没有自然流量，下载主要来自自己验证。推广的目标不是「放大已有流量」，而是先建立第一批真实用户和反馈。

**4 周目标（保守）**：

| 指标 | 目标 |
|---|---|
| Stars（两仓库合计） | 30 |
| 站点唯一访客 | 300 |
| macOS DMG 下载（增量） | 100 |
| Windows exe 下载（增量） | 40 |
| 有效反馈（issue / 私信 / 评论） | 10 |
| 安装成功率（能正常打开并看到数据） | 至少 80% |

每周日复盘一次，只记录事实，不因为单日波动改方向。

## 3. 渠道与素材

| 渠道 | 语气 | 素材 | 文案 | 备注 |
|---|---|---|---|---|
| X | 英文、开发者、简短 | `promo/assets/ccbar-demo.gif` | `promo/posts/x-thread.md` | 7 条 thread，第 2 条带 GIF |
| 即刻 | 中文、个人、第一人称 | `xhs-1.png` 或 GIF | `promo/posts/jike.md` | 先发，收集第一轮反馈 |
| 掘金 | 中文、长文、技术细节 | 三张截图 + GIF | 由 `promo/posts/sspai.md` 改写 | 已发；新账号标签上限 2 个 |
| V2EX 分享创造 | 中文、技术、坦诚 | 官网/GitHub 截图即可 | `promo/posts/v2ex.md` | 工作日上午发，及时回帖 |
| 小红书 | 中文、场景化、短句 | `xhs-1/2/3.png` | `promo/posts/xiaohongshu.md` | 三篇分周发，链接放评论区 |
| 少数派 | 中文、长文、技术细节 | 三张截图 + GIF | `promo/posts/sspai.md` | 需投稿审核，不要写成广告 |

### 配图与视频

- 演示 GIF：`promo/assets/ccbar-demo.gif`（1000×667，约 3.9 MB）
- 网页 / README 版：`docs/images/ccbar-demo.gif`（600×400，约 1.2 MB，另复制到 `web/assets/`）
- 小红书三张：`promo/assets/xhs-1.png`、`xhs-2.png`、`xhs-3.png`（1080×1440）
- 现有静态截图：`docs/images/{menubar,popover,insights,credits}.png`

GIF 目前是由静态截图做缓慢推近 + 三幕交叉淡入，不是真实录屏。真实点击流程需要录屏；如果之后补录，优先替换 X 和 README 的版本。

### 链接跟踪

统一使用官网链接并带 UTM，方便区分渠道：

- X：`https://ccbar-jjawpfzj0an.qoder.website/?utm_source=x&utm_medium=social&utm_campaign=launch`
- 即刻：`...?utm_source=jike&utm_medium=social&utm_campaign=launch`
- 掘金：`...?utm_source=juejin&utm_medium=article&utm_campaign=launch`
- V2EX：`...?utm_source=v2ex&utm_medium=forum&utm_campaign=launch`
- 小红书：`...?utm_source=xhs&utm_medium=social&utm_campaign=launch`
- 少数派：`...?utm_source=sspai&utm_medium=article&utm_campaign=launch`

GitHub 侧看 `traffic/popular/referrers` 和 Release 下载量；如果 Qoder Sites 后台提供来源统计，以站点后台为准。

## 4. 三周节奏

### 第 1 周（10/26 - 11/01）：物料与转化打底

- [x] README 顶部加演示 GIF、macOS / Windows 下载入口、Gatekeeper 说明
- [x] 官网加演示 GIF、安装一行命令；重新发布站点并线上核对
- [ ] 检查所有下载链接（DMG 最新版、Windows latest exe、GitHub 仓库）
- [ ] X thread 周二 10/27 上午发（美西时间 09:00 左右）
- [x] 即刻已发（10/25，提前，长文案 + 4 图，不含 GitHub 链接）：https://web.okjike.com/u/8C88F7B5-2725-46AD-A398-5F18AE8A95B6/post/6addf3cedbb645e5cbfb646c
- [x] 掘金已发（10/25，长文 + 4 图，分类：开发工具）：https://juejin.cn/post/7700380674943107082
- [ ] 记录首轮反馈，能当场修的安装/口径问题优先修

本周不急着上 V2EX 和小红书。先把落地页和安装摩擦处理掉，否则流量来了也接不住。

### 第 2 周（11/02 - 11/08）：中文社区第一波

- [ ] V2EX「分享创造」周二 11/03 10:30 发，当天盯回帖
- [ ] 小红书第一篇周三 11/04 20:30 发
- [ ] 小红书第二篇周五 11/06 20:30 发
- [ ] 周日复盘：访问、下载、安装问题、评论高频问题

发布后 24 小时内至少回复两次，不要只丢链接。遇到「为什么不用 xx」这类问题，按第 7 节模板回答，不争输赢。

### 第 3 周（11/09 - 11/15）：长文与二次触达

- [ ] 少数派长文周一 11/09 投稿（如果被拒，转投掘金 / 少数派 Matrix，不要同一时间重复投）
- [ ] X 周五 11/13 发一条 follow-up：这周收到的反馈 + 实际修了什么
- [ ] 小红书第三篇周五 11/13 20:30 发（趋势/洞察角度）
- [ ] 周日做 4 周复盘，决定是否继续投放或转向产品打磨

## 5. 转化优化清单

优先级从高到低：

1. **Apple 公证**（阻塞，需 Apple Developer Program，99 美元/年）：解决「无法验证开发者」是最高杠杆的转化改进。
2. **国内下载镜像**（需选托管）：GitHub Releases 在国内可能很慢。建议自有对象存储 + 自定义域名，不要用不可信的第三方加速代理。备选 Cloudflare R2（有免费额度）或阿里云 OSS。
3. **README 首屏**：演示 GIF、两条下载链接、macOS 13+ / Windows 10+、MIT、Gatekeeper 一行命令。
4. **官网下载区**：主按钮明确版本与架构；安装说明补一行 `xattr` 命令；Windows 入口不要藏在页面底部。
5. **首次启动**：设置页的数据源检测要能直接告诉用户「未检测到 cc-switch / ZCode」，而不是只显示空数据。
6. **真实录屏**：替换静态图推近版 GIF，展示点击菜单栏 → 弹窗 → 洞察中心 → 积分页的真实路径。

## 6. 指标记录表

每周日填：

| 周次 | 日期 | Stars | 站点唯一访客 | DMG 下载 | exe 下载 | 有效反馈 | 备注 |
|---|---|---|---|---|---|---|---|
| 基线 | 2026-10-25 | 1 | 2（14 天） | 4（累计） | 4（累计） | 0 | 自然流量几乎为零 |
| W1 | 2026-11-01 |  |  |  |  |  | X + 即刻 |
| W2 | 2026-11-08 |  |  |  |  |  | V2EX + 小红书 |
| W3 | 2026-11-15 |  |  |  |  |  | 少数派 + follow-up |
| W4 | 2026-11-22 |  |  |  |  |  | 复盘 |

## 7. 常见问题回复模板

**数据会上传吗？**
不上传。cc-switch 和 ZCode 的数据库是只读打开的，历史补进本机 SQLite；Trae 用你自己的凭据直接请求官方接口。没有账号系统，也没有遥测。

**为什么 macOS 提示无法验证开发者？**
安装包还没做 Apple 公证。首次打开右键选择「打开」，或者执行 `xattr -dr com.apple.quarantine /Applications/CCBar.app`。公证在计划里。

**支持 Cursor / Copilot / 其他 CLI 吗？**
目前只接了 cc-switch、ZCode、Trae。cc-switch 已经覆盖 Claude Code、Codex、OpenCode 等走代理的应用；新的来源可以按适配器接，欢迎提需求。

**Trae 登录过期怎么办？**
重新粘贴 sessionid 或整段 Cookie。v1.9.20 支持裸 sessionid、`sessionid=...`、完整 Cookie 和 `X-Cloudide-Session=...`，只改粘贴格式不会清空本地历史。

**和 xx 用量工具比呢？**
如果你只用一家 CLI，系统自带统计可能就够了。CCBar 的差异是多来源汇总、Trae 积分和本地优先；不需要这些的话不必换。

**Windows 和 macOS 一样吗？**
核心用量、积分和托盘功能接近，界面和部分洞察页仍在持续对齐，具体以 ccbar-win 仓库为准。

## 8. 不要做的事

- 不伪造用户评价、下载量或截图
- 不群发私信、不在无关话题下刷链接
- 不在同一时间把同一篇文案复制到所有渠道
- 不承诺「永久免费」「绝对准确」「支持所有 AI 工具」
- 不引导刷 Star；Star 只作为结果指标，不作为行动指标
- 不把 `.trae/`、本地数据库、日志或凭据截图发到公开渠道

## 9. 当前阻塞

| 事项 | 阻塞原因 | 需要谁决定 |
|---|---|---|
| Apple 公证 | 需要 Apple Developer Program（99 美元/年） | 用户 |
| 国内下载镜像 | 需要选托管与预算 | 用户 |
| 真实录屏 GIF | 无辅助功能权限，自动化点击受限 | 用户手动录屏或授权 |
| 少数派投稿 | 需要账号，且可能被编辑拒稿 | 用户 |
| 小红书发布 | 需要账号，链接可能限流 | 用户 |

在阻塞解除前，先执行不依赖它们的部分：README/官网转化、X、即刻、V2EX。
