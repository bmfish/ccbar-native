# 小红书 · 三篇

配图：`promo/assets/xhs-1.png`、`xhs-2.png`、`xhs-3.png`
发布时把官网和 GitHub 放在评论区置顶，正文里只写“GitHub 搜 ccbar-native”。

## 第一篇：今日用量（主推）

标题：AI 一天烧了多少钱？我把它放进了菜单栏

正文：

同时用 Claude Code、Codex、Trae 和 GLM 之后，我最大的疑问变成了：今天到底烧了多少？

于是写了个小工具 CCBar：

- 菜单栏实时显示今日 token，用量越大颜色越醒目
- 点开能看到请求数、缓存命中、工时和积分
- 近 7 天 / 近 30 天 / 历史总量，还有模型分布
- Trae 积分单独一页：今日用了多少、余额还能撑几天
- 数据只存在本机，源数据库只读，不注册也不上传
- macOS 13+ 和 Windows 都能用，开源免费

macOS 安装包没有做苹果公证，第一次打开要右键选择“打开”。

GitHub 搜：ccbar-native，官网放在评论区。

#AI编程 #ClaudeCode #Codex #Trae #程序员工具 #效率工具 #macOS #独立开发

---

## 第二篇：积分与余额

标题：Trae 积分还能用几天？

正文：

写代码的时候最怕两件事：token 没了，积分也快没了。

CCBar 的积分页会把 Trae 的今日积分、账户余额和可用天数放在一起：

- 今日积分和请求数、缓存命中、工时同屏
- 余额按近 7 天日均消耗折算，直接告诉你还能用几天
- 近 7 天 / 近 30 天积分走势，峰值日一眼能看到
- 数据本地存储，不用把 sessionid 交给第三方

它也能同时统计 Claude Code、Codex 和 GLM 的 token 用量，macOS 菜单栏和 Windows 托盘都能跑。

GitHub 搜：ccbar-native。

#Trae #AI编程 #积分 #程序员日常 #效率工具 #macOS #Windows #独立开发

---

## 第三篇：趋势与洞察

标题：别只看今天，AI 用量要看趋势

正文：

只看今天的 token，很容易低估自己到底用了多少。

CCBar 的洞察中心更像一个用量复盘面板：

- 近 30 天走势、日均、单日峰值和历史总量
- 90 天热力图，哪几天在疯狂写代码一目了然
- 模型编年史，看你从哪个模型换到了哪个模型
- 渠道构成、费用排行、性价比和月度预算
- 周报卡和战报卡可以保存分享

所有统计都在本机完成，源数据库只读，历史每天补进本地 SQLite。macOS 13+ 和 Windows 都有，MIT 开源。

GitHub 搜：ccbar-native。

#AI编程 #ClaudeCode #Codex #Trae #数据可视化 #程序员工具 #效率工具 #macOS
