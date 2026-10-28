# CCBar 本地 CLI / JSON API 计划（功能 16）

- 状态：待评审，未开工
- 目标版本：v1.10.0
- 预估：2–3 天
- 范围：本地只读查询 + 打开窗口；不含远程访问和数据写入

## 1. 背景与目标

CCBar 目前只能在菜单栏和窗口里看数据。希望让脚本、状态栏工具、Raycast / Shortcuts、自定义面板能直接拿到同一份统计结果，并且能一键打开 CCBar 的某个页面。

目标：

1. 提供 `ccbar` 命令行，输出人类可读摘要或 `--json`。
2. 数字与 UI 完全一致，不维护第二套统计逻辑。
3. 支持 `today / week / month / all` 以及模型、数据源维度。
4. 提供 `ccbar://` URL Scheme，供外部工具直接打开洞察页。
5. 不引入网络端口，不新增后台常驻进程。

典型使用场景：

```bash
# tmux / SketchyBar / 自建状态栏
ccbar stats today --json | jq '.data.tokens.total'

# 每日脚本
ccbar stats week --json >> ~/usage-weekly.jsonl

# Raycast / Shortcuts / 浏览器书签
open "ccbar://open/timeline"
```

## 2. 非目标

- 不做 HTTP / TCP 接口，不暴露到局域网。
- 不做写入、删除、导入导出、触发同步。
- 不做历史明细逐条导出（已有 CSV）。
- 不做常驻 daemon；数据服务依附于正在运行的 CCBar.app。
- 不承诺 CLI 在 app 未安装时可用（开发态用环境变量兜底）。

## 3. 方案选型

### 3.1 候选方案

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| CLI 直连 SQLite | 不依赖 app 运行 | 今日数据依赖 `ATTACH` + `TEMP VIEW usage_all`，CLI 要重复实现整套取数；与 UI 口径容易漂移 | 否 |
| XPC Service | 苹果原生、权限清晰 | 需要额外 service bundle、打包和签名复杂，脚本调用不直观 | 否 |
| 本地 HTTP（127.0.0.1） | 通用、易调试 | 需要端口管理、可能被其他本机进程访问、防火墙/端口冲突 | 否 |
| **Unix Domain Socket + 薄 CLI** | 同用户权限、无端口、协议简单、复用 app 内查询 | app 必须运行（可自动拉起）、需要处理残留 socket | **采用** |
| URL Scheme（单独） | 打开窗口方便 | 只能传 URL，不能返回统计数据 | 作为补充保留 |

### 3.2 架构

```
┌─────────────┐    JSON line    ┌──────────────────────────────┐
│ ccbar CLI   │ ──────────────► │ CCBar.app                     │
│ (薄客户端)  │ ◄────────────── │  CLIServer (Unix socket 0600) │
└─────────────┘                 │    └─ CLIStatsService         │
       │                        │         └─ StatsStore         │
       │ app 未运行              │              └─ SQLite       │
       └── open -b ───────────► │                              │
                                └──────────────────────────────┘
```

- socket：`~/Library/Application Support/ccbar/cli.sock`
- CLI：随 app 打包在 `CCBar.app/Contents/Helpers/ccbar`
- 数据：全部通过 app 内现有 `StatsStore` 查询，保证与菜单栏/洞察中心一致
- 打开页面：CLI 通过 socket 发 `open` 命令；外部工具走 `ccbar://` URL Scheme

### 3.3 为什么不让 CLI 直连数据库

今日数据并不是单纯存在 `ccbar.db` 里：

- cc-switch / ZCode 的今日数据通过 `ATTACH` 读取源库；
- `usage_all` 是连接内的 `TEMP VIEW`，把自有历史和各源今日片段 UNION 起来；
- 各源同步状态、水位、凭证都在 app 进程内维护。

CLI 自己拼一套 SQL，短期能跑，长期一定会出现「UI 和 CLI 数字不一样」的问题。走 app 内查询是刻意选择。

## 4. 协议 v1

### 4.1 传输

- Unix Domain Socket，`SOCK_STREAM`
- 一个连接一个请求：客户端发送一行 JSON + `\n`，服务端返回一行 JSON + `\n`，随后关闭
- 请求上限 4 KB；响应上限 256 KB
- 服务端串行处理，避免并发打满 SQLite 锁
- 连接建立后校验 peer UID（`getpeereid`），只接受当前用户

### 4.2 请求

```json
{"v":1,"cmd":"ping"}
{"v":1,"cmd":"stats","period":"today"}
{"v":1,"cmd":"models","period":"week"}
{"v":1,"cmd":"sources","period":"all"}
{"v":1,"cmd":"open","page":"timeline"}
```

字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `v` | Int | 协议版本，当前固定 `1` |
| `cmd` | String | `ping` / `stats` / `models` / `sources` / `open` |
| `period` | String? | `today` / `week` / `month` / `all`，`stats` 必填，默认 `today` |
| `page` | String? | `insights` / `credits` / `timeline` / `channels` / `cost` / `share` / `settings` / `detail` |

### 4.3 成功响应

```json
{
  "ok": true,
  "v": 1,
  "generated_at": "2026-10-25T15:04:05+08:00",
  "data": {
    "period": "week",
    "range": { "from": "2026-10-19", "to": "2026-10-25" },
    "requests": 1234,
    "tokens": {
      "input": 1000000,
      "output": 200000,
      "cache_create": 150000,
      "cache_read": 300000,
      "total": 1650000
    },
    "cost_usd": 12.34,
    "credits": 56.7,
    "models": [
      { "model": "claude-sonnet-4", "input": 800000, "output": 150000, "total": 1250000 }
    ],
    "sources": [
      { "source": "cc-switch", "requests": 900, "total": 1200000 }
    ]
  }
}
```

约定：

- `tokens.total = input + output + cache_create + cache_read`，与 UI 的 `DayStats.total` 一致。
- `cost_usd` 取记录里的 `total_cost_usd` 汇总，不重新按价格计算。
- `credits` 仅 Trae 行有值，其他源为 0；口径与积分页一致。
- `range.from` 在 `period=all` 时为 `null`。
- `generated_at` 使用本地时区 ISO8601；不额外输出 epoch，避免脚本歧义。
- `models` / `sources` 按 token 降序；默认最多 20 条。

### 4.4 错误响应

```json
{
  "ok": false,
  "v": 1,
  "error": {
    "code": "bad_request",
    "message": "period 必须是 today/week/month/all"
  }
}
```

错误码：

| code | 场景 |
| --- | --- |
| `bad_request` | JSON 非法、字段缺失、命令参数错误 |
| `unsupported_version` | `v` 不是 1 |
| `unknown_command` | 未知 `cmd` |
| `unknown_page` | 未知页面 |
| `internal` | 查询异常 |

## 5. 命令设计

### 5.1 命令列表

```text
ccbar stats [today|week|month|all] [--json]
ccbar models [today|week|month|all] [--json]
ccbar sources [today|week|month|all] [--json]
ccbar open <insights|credits|timeline|channels|cost|share|settings|detail>
ccbar ping [--json]
ccbar install-cli [--uninstall]
ccbar --version
ccbar --help
```

- 不引入 `swift-argument-parser`，手写参数解析，保持零第三方依赖。
- 位置参数 `period` 也接受 `--period=week` 形式。
- 默认输出人类可读文本；`--json` 输出单行 JSON，便于管道处理。
- 带 `--json` 时错误也输出 JSON 到 stdout；不带时错误写 stderr。
- 所有查询命令都强制只读。

### 5.2 人类可读输出示例

```text
$ ccbar stats today
今日 · 2026-10-25
请求 1,234    Tokens 1.65M    费用 $12.34    积分 56.7

模型
claude-sonnet-4    1.25M
gpt-5              0.40M

数据源
cc-switch          900 次 · 1.20M
trae               334 次 · 0.45M
```

### 5.3 退出码

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 2 | 用法错误 |
| 3 | app 未启动且自动拉起失败 / socket 不可用 |
| 4 | 协议错误或服务端返回错误 |
| 5 | 协议版本不兼容 |

### 5.4 冷启动与重试

1. CLI 先尝试连接 socket。
2. 连接失败（`ENOENT` / `ECONNREFUSED`）时自动拉起 app：
   - 优先使用 `CCBAR_APP_PATH`（开发调试）；
   - 否则如果自身路径位于 `CCBar.app/Contents/Helpers/`，用 `open` 打开所在 app；
   - 否则 `open -b com.bmfish.ccbar-native`。
3. 每 100 ms 重试连接，最多 3 秒；成功后先发 `ping` 再发真实请求。
4. 3 秒内仍失败，退出码 3，并提示「请安装并启动 CCBar」。

说明：`ccbar stats` 不会主动触发数据源同步，返回 app 当前状态；app 默认每 30 秒刷新一次。

## 6. 数据口径与查询映射

`CLIStatsService` 集中做 period → 查询的映射，避免命令层散落逻辑。

| period | token / 请求 | 费用 | 积分 | 模型 / 数据源范围 |
| --- | --- | --- | --- | --- |
| `today` | `queryDayStats(days: 0)` | `queryCost(days: 1)` | `queryCreditsSum(days: 1)` | 今日实时 |
| `week` | `queryDayStats(days: 7)` | `queryCost(days: 7)` | `queryCreditsSum(days: 7)` | 近 7 天（含今天） |
| `month` | `queryDayStats(days: 30)` | `queryCost(days: 30)` | `queryCreditsSum(days: 30)` | 近 30 天（含今天） |
| `all` | `queryTotalStats()` | 新增 `queryCostTotal()` | `queryCreditsTotal()` | 全量 |

模型 / 数据源需要补两个可按区间查询的方法：

```swift
// 现有 UI 用法改为调用新方法，行为不变
func queryModelBreakdown() -> [ModelStat]
func queryModelBreakdown(from: Int64?, to: Int64) -> [ModelStat]
func querySourceBreakdown() -> [SourceStat]
func querySourceBreakdown(from: Int64?, to: Int64) -> [SourceStat]
```

- `from == nil` 表示全量。
- 区间上限统一取 `localMidnight(-1)`，包含今天实时数据。
- 现有 `queryModelBreakdown()` 和 `querySourceBreakdown()` 保持签名，内部转调新方法，避免影响 UI。
- 额外新增 `queryCostTotal()`，一条全表 `SUM(total_cost_usd)`；数据量在几万行级别，可接受。

## 7. 代码改动

### 7.1 新增 `Sources/CCBarIPC/Protocol.swift`

共享协议模块，app 和 CLI 都依赖，避免两边手写字符串：

```swift
public enum CLIPeriod: String, Codable, CaseIterable {
    case today, week, month, all
}

public enum CLIPage: String, Codable, CaseIterable {
    case insights, credits, timeline, channels, cost, share, settings, detail
}

public struct CLIRequest: Codable {
    public var v: Int
    public var cmd: String
    public var period: CLIPeriod?
    public var page: CLIPage?
}

public struct CLIResponse: Codable { /* ok / v / generated_at / data / error */ }

public let cliProtocolVersion = 1
public let cliMaxRequestBytes = 4096
public let cliMaxResponseBytes = 256 * 1024
```

只放协议类型和编解码常量，不放业务逻辑。

### 7.2 新增 `Sources/CCBar/CLIServer.swift`

- POSIX socket：`socket` / `bind` / `listen` / `accept`。
- 启动时先 `unlink` 旧 socket，`umask(0o077)` 期间创建，`chmod 0600`。
- 使用 `DispatchSource.makeReadSource` 监听，串行队列处理请求。
- 注入 socket 路径和 `openPage` 回调，方便测试。
- 停止时关闭 fd 并删除 socket；`applicationWillTerminate` 调用。
- 只解析一行请求；超长请求直接返回 `bad_request` 并关闭。
- 响应编码后超过 256 KB 时截断 models/sources 条目，不返回半截 JSON。
- 第二个 app 实例 bind 失败时只记日志，不影响 app 启动。

### 7.3 新增 `Sources/CCBar/CLIStatsService.swift`

- `stats(period:store:)`
- `models(period:store:)`
- `sources(period:store:)`
- 负责周期范围、格式化、模型/数据源截断
- 纯函数式依赖 `StatsStore`，可单测

### 7.4 新增 `Sources/ccbar-cli/main.swift`

- 参数解析、帮助、版本
- Unix socket 客户端、超时、自动拉起、重试
- 人类可读渲染 + `--json`
- `install-cli`：复制自身到 `~/.local/bin/ccbar`（`--uninstall` 删除），并提示 PATH
- 开发态支持 `CCBAR_APP_PATH`

为什么 `install-cli` 用复制而不是软链：

- 软链指向 app 包内路径，用户移动/重装 app 后容易断
- 复制后 CLI 独立可用；app 升级后重新执行一次 `ccbar install-cli` 即可
- 协议 v1 保持稳定，旧 CLI 在新 app 上仍可工作

### 7.5 修改 `Package.swift`

```swift
.target(name: "CCBarIPC", path: "Sources/CCBarIPC"),
.executableTarget(
    name: "CCBar",
    dependencies: ["CCBarIPC"],
    path: "Sources/CCBar",
    linkerSettings: [...]
),
.executableTarget(
    name: "ccbar",
    dependencies: ["CCBarIPC"],
    path: "Sources/ccbar-cli"
),
products: [
    .executable(name: "CCBar", targets: ["CCBar"]),
    .executable(name: "ccbar", targets: ["ccbar"]),
],
```

注意保持 `swift-tools-version: 5.9` 和现有平台声明不变。

### 7.6 修改 `Sources/CCBar/AppDelegate.swift`

- 启动完成后调用 `cliServer.start()`（store 初始化之后）。
- `applicationWillTerminate` 调用 `cliServer.stop()`。
- 新增：

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { handleCLIURL(url) }
}
```

- URL 路由：

| URL | 动作 |
| --- | --- |
| `ccbar://open/insights` | `showInsights(page: .insights)` |
| `ccbar://open/credits` | `showInsights(page: .credits)` |
| `ccbar://open/timeline` | `showInsights(page: .timeline)` |
| `ccbar://open/channels` | `showInsights(page: .channels)` |
| `ccbar://open/cost` | `showInsights(page: .cost)` |
| `ccbar://open/share` | `showInsights(page: .share)` |
| `ccbar://open/settings` | `showInsights(page: .settings)` |
| `ccbar://open/detail` | `openDetail()` |

未知 page 忽略并记录日志；URL 解析逻辑单独抽函数，便于单测。

### 7.7 修改 `scripts/package.sh`

- 构建后同时定位 `ccbar` 产物（单架构和 universal 的三条候选路径与主程序一致）。
- 创建 `CCBar.app/Contents/Helpers/`，复制 `ccbar`。
- Info.plist 增加：

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.bmfish.ccbar-native</string>
    <key>CFBundleURLSchemes</key>
    <array><string>ccbar</string></array>
  </dict>
</array>
```

- universal 模式用 `lipo -archs` 校验两个二进制都含 `x86_64`。
- 现有 `codesign --force --deep -s -` 会一并签 Helper；打包后验证 `codesign --verify --deep --strict`。

### 7.8 文档

- README 增加「命令行 / 本地 API」一节：安装、示例、JSON 字段、URL Scheme。
- 说明数据口径、app 必须运行、隐私边界（只读本机、无网络）。
- 变更记录加入 v1.10.0。

## 8. 安全与隐私

- 只监听 Unix socket，不监听 TCP 端口。
- socket 权限 `0600`，peer UID 校验为当前用户。
- 目录使用用户级 `Application Support`，不写入全局路径。
- 只读命令；协议里没有写操作、没有「执行 shell」类字段。
- 响应只包含聚合统计，不包含 Trae JWT、cc-switch 凭证、会话 ID、原始 prompt/response。
- CLI 不读取数据库文件，不绕过 app 的数据源配置。
- 本机同用户进程本来就能读取 `~/Library/Application Support/ccbar/ccbar.db`，socket 不扩大实质攻击面；但额外做了权限收敛。

## 9. 错误处理与边界

| 场景 | 行为 |
| --- | --- |
| app 未运行 | CLI 自动拉起并重试 3 秒；失败退出码 3 |
| app 启动中 socket 未就绪 | 同上，通过 `ping` 判定就绪 |
| 残留 socket 文件 | app 启动时 unlink 后重建；CLI 遇到 `ECONNREFUSED` 触发拉起 |
| 第二个 app 实例 | bind 失败，记录日志，不崩溃、不删除已有 socket |
| 旧版 CLI 连新版 app | `v` 不匹配返回 `unsupported_version`，CLI 提示升级 |
| 新版 CLI 连旧版 app | 旧 app 没有 socket，CLI 提示升级 CCBar |
| 请求超长 | 返回 `bad_request`，关闭连接，服务端继续可用 |
| 查询耗时过长 | CLI 3 秒超时，退出码 4；不影响 UI |
| 响应过大 | 限制 models/sources 条数，保证完整 JSON |
| socket 路径超过 `sun_path` 限制 | 启动时校验并输出明确日志，不静默失败 |

## 10. 测试计划

### 10.1 单元测试

- `CLIProtocolTests`
  - 请求 / 响应 Codable 往返
  - 非法版本、未知命令、未知页面解码
  - 超长请求判定
- `CLIStatsServiceTests`
  - 用临时 SQLite 造数据，`today/week/month/all` 与 `StatsStore` 直接查询结果逐字段相等
  - 模型 / 数据源排序、截断
  - 无数据源时返回空结构而不是崩溃
- `CLIURLTests`
  - 8 个 `ccbar://open/...` 路由
  - 非法 scheme / 未知 page 忽略
- `CLIServerTests`
  - 临时 socket 路径启动，真实连接往返
  - 畸形 JSON、超长请求、连续两次请求
  - socket 权限为 `0600`
  - `openPage` 回调被调用且在主线程

### 10.2 集成与手工验收

1. `swift test` 全绿，CI `Test` workflow 通过。
2. 打包 DMG，安装后：
   - `CCBar.app/Contents/Helpers/ccbar` 存在且可执行；
   - `plutil -p CCBar.app/Contents/Info.plist` 能看到 URL Scheme；
   - `codesign --verify --deep --strict CCBar.app` 通过。
3. 打开 CCBar，执行：
   - `ccbar stats today --json | jq .data`；
   - `ccbar stats week`、`ccbar models month`、`ccbar sources all`；
   - 与 UI 对应页面数字对照，必须一致。
4. 退出 CCBar，执行 `ccbar stats today`，确认 app 被自动拉起并在 3 秒内返回。
5. 执行 `ccbar open credits`，确认洞察中心打开并定位到积分页。
6. 浏览器打开 `ccbar://open/timeline`，确认窗口打开。
7. `ccbar install-cli` 后从其他目录执行 `ccbar stats today`。
8. 监听 `lsof -U | grep cli.sock`，确认不是 TCP 端口。

### 10.3 验收标准

- CLI JSON 与 UI 同一周期、同一口径的数字完全一致。
- app 冷启动场景可用，不要求用户先手动打开 app。
- 任何畸形请求都不会导致 app 崩溃或 socket 无法继续服务。
- 不新增第三方依赖，`swift build` / `swift test` 在 CI macOS runner 上通过。
- README 有完整使用说明，用户不需要读源码。

## 11. 里程碑

| 阶段 | 内容 | 预估 |
| --- | --- | --- |
| M1 | `CCBarIPC` 协议、`CLIServer`、app 启停接入、`stats today/week/month/all` | 0.5–1 天 |
| M2 | `models` / `sources` 区间查询、人类可读输出、错误码与超时 | 0.5 天 |
| M3 | `open` 命令、URL Scheme、自动拉起重试、`install-cli` | 0.5 天 |
| M4 | package.sh、单元测试、README、打包验收 | 0.5–1 天 |

## 12. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| app 未安装 / 开发态无法 `open -b` | CLI 无法冷启动 | `CCBAR_APP_PATH` 环境变量 + 从 Helper 路径反推 app + 明确错误提示 |
| 用户移动 app 后 `install-cli` 的副本过期 | 协议旧但一般仍可用 | 协议 v1 保持兼容；文档提示升级后重跑 `install-cli` |
| app 同步持锁导致查询慢 | CLI 超时 | 串行队列 + 3 秒超时；聚合查询本身为毫秒级 |
| socket 文件残留 | 冷启动误判 | app 启动 unlink 重建；CLI 收到拒绝后拉起并重试 |
| 与未来 App Sandbox 不兼容 | socket 路径受限 | 当前未启用 sandbox；若启用需把 socket 移入容器并升级协议 |
| 多实例 | bind 冲突 | 第二个实例只记录日志，不退出、不删除 socket |
| 协议演进 | 新旧不匹配 | `v` 字段 + `unsupported_version` + 清晰升级提示 |

## 13. 后续可扩展（不在本期）

- `ccbar history --days 30 --json` 日粒度趋势
- `ccbar export --format csv --out -` 复用现有导出
- `ccbar refresh` 主动触发同步并等待完成
- `ccbar://open/detail?date=...` 带参数打开指定日期
- 只读 HTTP 兼容层（供不支持 Unix socket 的工具），默认关闭
- Prometheus textfile exporter 脚本示例

## 14. 开工前确认项

以下按推荐默认执行，评审时如有不同意见再改：

1. CLI 名称用 `ccbar`，随 app 打包，不单独发 Homebrew formula。
2. 只读，不做同步触发；数据新鲜度依赖 app 的 30 秒刷新。
3. `install-cli` 采用复制而非软链。
4. 协议 v1 只支持聚合统计，不支持逐条明细。
5. 目标版本 v1.10.0。
