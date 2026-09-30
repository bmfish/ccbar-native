# CCBar

macOS 菜单栏 AI CLI 用量统计工具。实时显示今日 token 消耗，支持**多数据源**聚合——目前内置 [cc-switch](https://github.com/farion1231/cc-switch)（Claude/Codex 等多应用代理统计）与 ZCode，后续可插拔扩展。

![menu bar](https://img.shields.io/badge/platform-macOS%2012%2B-black) ![swift](https://img.shields.io/badge/swift-5.9-orange) ![windows](https://img.shields.io/badge/Windows-tray-blue) ![license](https://img.shields.io/badge/license-MIT-green)

<!--
📷 截图待补：拍好后放到 docs/images/ 并解开下面的注释（建议尺寸裁剪到内容区）

1. docs/images/menubar.png    菜单栏数字（最好抓到变色或里程碑 🫧 气泡的瞬间）
2. docs/images/popover.png    弹窗面板（今日卡片 + 模型分布 + 趋势）
3. docs/images/channels.png   模型分布详情（按渠道分组）
4. docs/images/weekly.png     周/月柱状图

<p align="center">
  <img src="docs/images/menubar.png" width="220" alt="菜单栏">
  <img src="docs/images/popover.png" width="320" alt="弹窗面板">
  <img src="docs/images/channels.png" width="420" alt="模型分布详情">
  <img src="docs/images/weekly.png" width="420" alt="周/月用量">
</p>
-->

## English

CCBar is a native macOS menu bar app that tracks your AI CLI token usage in real time — today, this week, and all-time — with **pluggable data sources**: [cc-switch](https://github.com/farion1231/cc-switch) (Claude Code / Codex / OpenCode via proxy) and ZCode (GLM). History is synced daily into a local SQLite store (source databases are opened read-only and never modified), while today's numbers are queried live. Milestone notifications, quota warnings, per-channel breakdowns, and a Windows system tray version are included.

## 功能

- **菜单栏实时用量**：标题栏直接显示今日 token 总量，按用量阈值变色，每 30 秒（可调）刷新
- **用量预警 / 里程碑**：超过阈值或每累计 N 万 token 弹出系统通知，陪你刷量 🫧
- **弹窗面板**：今日卡片（请求数 / 缓存命中率 / 工时）、模型分布、趋势（昨日 / 近7天 / 近30天 / 历史总量）
- **详情窗口**：近 7 天、近 30 天（柱状图）、模型分布（环形图 + 按渠道分组明细）、每小时分布
- **多数据源**：每个源可独立启用 / 停用、自定义数据库路径
- **多主题**：六套配色主题，菜单栏与弹窗跟随切换

## 数据架构

ccbar 自带一个统计库（`~/Library/Application Support/ccbar/ccbar.db`），对外部源库**全程只读**：

```
自建库（主连接）
 ├── usage_log   统一明细表（昨天及更早的历史，每日懒惰补账同步进来）
 ├── meta        各源同步水位
 └── usage_all   视图 = 自家历史 + 各启用源"今日"实时数据
      ├── ATTACH ~/.cc-switch/cc-switch.db   (只读)
      └── ATTACH ~/.zcode/cli/db/db.sqlite   (只读)
```

- **历史**（昨天及更早）：每天首次刷新时自动补账进自家库，源库清理不影响已有统计
- **今日**：每次刷新实时查各源库汇总，零延迟
- 两段在 `usage_all` 视图中拼接，查询侧不区分数据来自哪一路

### 统计口径

| 数据源 | 口径 | 说明 |
|---|---|---|
| cc-switch | input + output + 缓存读 + 缓存创建 | 全量 token 流量，费用按 cc-switch 记录的单价折算 |
| ZCode | input + output | 与 ZCode 官方统计一致（`computed_total_tokens`），缓存命中不计入，可直接与 ZCode 界面对账 |

## 添加新数据源

实现 `SourceAdapter` 协议并注册一行即可，同步、视图、设置 UI 自动生效：

```swift
struct MyAdapter: SourceAdapter {
    let id = "myapp"
    let name = "MyApp"
    let defaultPath = "\(NSHomeDirectory())/.myapp/stats.db"
    let alias = "src_my"
    let requiredTables = ["requests"]

    func attachSQL(fileURL: String) -> String { "ATTACH DATABASE 'file:\(fileURL)?mode=ro' AS \(alias)" }
    func syncSQLs(alias: String, fromDay: String, today: String) -> [String] { /* INSERT OR IGNORE INTO usage_log ... */ }
    func todayFragment(alias: String) -> String { /* usage_all 的"今日"UNION 段 */ }
}

// SourceRegistry.adapters 中注册
```

## 构建

```bash
swift build -c release

# 打包 app（改 Info.plist 版本号后）
cp .build/release/CCBar CCBar.app/Contents/MacOS/CCBar
codesign --force --deep -s - CCBar.app

# 打安装包
hdiutil create -volname "CCBar" -srcfolder CCBar.app -ov -format UDZO CCBar-<版本>-arm64.dmg
```

## 版本

- **v1.1.0** — 多数据源统计架构：自建统计库 + ZCode 接入（官方口径）、模型分布按渠道分组、亮色背景可读性修复
- **v1.0.0** — 多主题系统、柱状图、通知间隔、滚动支持
