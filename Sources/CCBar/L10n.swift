import Cocoa

// MARK: - 界面语言（中文 / English / 跟随系统）

/// 语言偏好：设置里可选，重启后生效
enum AppLanguage: String, CaseIterable {
    case system
    case zh
    case en

    var displayName: String {
        switch self {
        case .system: return L("跟随系统")
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    /// 解析到实际语言（跟随系统时看系统首选语言）
    var resolvesToEnglish: Bool {
        switch self {
        case .en: return true
        case .zh: return false
        case .system:
            return (Locale.preferredLanguages.first ?? "zh").hasPrefix("en")
        }
    }
}

enum L10n {
    /// 当前是否英文界面（启动时由语言偏好决定）
    static var isEnglish: Bool {
        (AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "")
         ?? .system).resolvesToEnglish
    }

    /// 取词条：中文原文 → 英文；缺词条回落中文（允许渐进式翻译）
    static func t(_ zh: String) -> String {
        isEnglish ? (L10nEN[zh] ?? zh) : zh
    }

    /// Token 数量：中文用 万/亿，英文用 K/M/B
    static func formatTokens(_ n: Int64) -> String {
        if isEnglish {
            let v = Double(n)
            if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
            if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
            if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
            return "\(n)"
        }
        if n >= 100_000_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return "\(n / 10_000)万" }
        return "\(n)"
    }
}

/// 全局词条：L("中文原文") → 当前语言文案
func L(_ zh: String) -> String {
    L10n.t(zh)
}

// MARK: - 英文词条表
//
// key = 中文原文（即代码里现存的字符串），value = 英文。
// 缺词条自动回落中文，允许渐进补齐；新增界面先写中文再来这里补英文。

let L10nEN: [String: String] = [
    // ---- 弹窗 ----
    "ccBar 用量统计": "ccBar Usage",
    "今日用量": "Today",
    "昨日": "Yesterday",
    "近7天": "7 Days",
    "近30天": "30 Days",
    "趋势": "Trend",
    "请求数": "Requests",
    "模型分布": "Models",
    "缓存命中": "Cache Hit",
    "工时": "Work Hours",
    "历史总量": "All Time",
    "刷新": "Refresh",
    "复制": "Copy",
    "设置": "Settings",
    "退出": "Quit",
    "暂无数据\n请检查设置里的数据源连接": "No data yet\nCheck data sources in Settings",
    "按当前速率到 24:00 约 %@": "At current rate, ~%@ by 24:00",

    // ---- 详情窗口 ----
    "近7天用量": "Last 7 Days",
    "近30天用量": "Last 30 Days",
    "模型分布详情": "Model Breakdown",
    "每小时用量": "Hourly Usage",
    "按月汇总": "By Month",
    "日期": "Date",
    "请求": "Reqs",
    "总 Token": "Tokens",
    "缓存读": "Cache Read",
    "时间": "Time",
    "月份": "Month",
    "模型": "Model",
    "合计": "Total",
    "暂无数据": "No data",
    "导出失败": "Export failed",
    "好的": "OK",

    // ---- 设置窗口 ----
    "主题风格": "Theme",
    "导入": "Import",
    "导出": "Export",
    "刷新间隔": "Refresh Interval",
    "秒": "s",
    "数据源": "Data Sources",
    "预警阈值": "Warn Threshold",
    "万": "×10K",
    "通知间隔": "Notify Every",
    "红色门槛": "Red Line",
    "超出时通知": "notify when exceeded",
    "每累计N万通知，0=关闭": "notify per N×10K, 0=off",
    "单次刷新增量达到变红，0=不变红": "icon turns red at this refresh delta, 0=off",
    "启用用量预警": "Enable usage warning",
    "开机自动启动": "Launch at Login",
    "菜单栏动画伴侣（小猫随用量跑动）": "Menu bar pet (cat runs with usage)",
    "菜单栏表情分级（🙂→🥵）": "Menu bar emoji tiers (🙂→🥵)",
    "宽版弹窗（380pt）": "Wide popover (380pt)",
    "重置": "Reset",
    "检查更新": "Check Updates",
    "备份数据": "Backup",
    "保存": "Save",
    "无法保存": "Can't save",
    "以下字段无效：": "Invalid fields:",
    "刷新间隔（5 ~ 3000 秒）": "Refresh interval (5 – 3000 s)",
    "预警阈值（正整数，万）": "Warning threshold (positive, ×10K)",
    "通知间隔（≥ 0 的整数，万，0=关闭）": "Notify interval (≥ 0, ×10K, 0=off)",
    "红色门槛（≥ 0 的整数，万，0=不变红）": "Red line (≥ 0, ×10K, 0=off)",
    "设置已保存": "Settings saved",
    "新的设置将在下次刷新时生效": "New settings take effect on next refresh",
    "备份完成": "Backup complete",
    "备份失败": "Backup failed",
    "统计库已备份到：": "Database backed up to:",
    "\n恢复方式：退出 ccBar 后用备份文件替换\n~/Library/Application Support/ccbar/ccbar.db":
        "\nTo restore: quit ccBar and replace\n~/Library/Application Support/ccbar/ccbar.db with the backup",
    "统计库未打开或目标位置不可写": "Database not open or target not writable",
    "导出完成": "Export complete",
    "主题包已保存到：": "Theme pack saved to:",
    "导入失败": "Import failed",
    "不是有效的 ccBar 主题包": "Not a valid ccBar theme pack",
    "导入成功": "Imported",
    "主题「%@」已加入可选列表": "Theme \"%@\" added to the list",
    "文件不存在": "File not found",
    "打不开（被占用或损坏）": "Can't open (locked or corrupted)",
    "缺少必需表": "Required tables missing",
    "校验失败": "Validation failed",
    "表结构正确（保存后生效）": "Schema OK (applied on save)",
    "已连接": "Connected",
    "未启用": "Disabled",
    "未连接": "Not connected",
    "界面语言": "Language",
    "重启后生效": "restart to apply",
    "ccbar-近7天.csv": "ccbar-7days.csv",
    "ccbar-近30天.csv": "ccbar-30days.csv",
    "ccbar-按月汇总.csv": "ccbar-by-month.csv",
    "ATTACH 失败（库可能被占用或损坏）": "Attach failed (locked or corrupted)",
    "跟随系统": "System",

    // ---- 更新 ----
    "发现新版本 v%@": "New version v%@",
    "当前版本 v%@。前往 GitHub Releases 下载最新 DMG。": "Current v%@. Get the latest DMG from GitHub Releases.",
    "前往下载": "Download",
    "以后再说": "Later",
    "已经是最新版本（v%@）": "Up to date (v%@)",
    "检查失败，稍后再试，或直接到 GitHub Releases 页面查看": "Check failed, try again later or visit GitHub Releases",

    // ---- 通知 / 菜单 ----
    "用量预警": "Usage Warning",
    "今日 Token 用量已达 %@，超过预警阈值 %d万": "Today's tokens reached %@ (warning line: %d×10K)",
    "🎉 用量里程碑": "🎉 Usage Milestone",
    "今日 Token 已达 %@（每%d万通知一次）": "Today's tokens reached %@ (every %d×10K)",
    "复制今日统计": "Copy Today's Stats",
    "已复制到剪贴板": "Copied to clipboard",
    "统计数据已复制，可直接粘贴使用": "Stats copied, ready to paste",
    "未找到": "No data",
    "今日：%@": "Today: %@",
    "\n昨日：%@": "\nYesterday: %@",
    "\n请求数：%d": "\nRequests: %d",
    "ccBar 今日用量统计\n": "ccBar Today's Usage\n",
    "Token 总量: %@\n": "Total Tokens: %@\n",
    "请求数量: %d\n": "Requests: %d\n",
    "输入 Token: %@\n": "Input: %@\n",
    "输出 Token: %@\n": "Output: %@\n",
    "缓存 Token: %@": "Cache: %@",
    "\n数据源分布:\n": "\nBy Source:\n",
    "\n模型分布:\n": "\nBy Model:\n",
    "今日详情": "Today Detail",
    "近7天详情": "7-Day Detail",
    "ccBar 设置": "ccBar Settings",
    "选择 %@ 数据库文件": "Choose %@ database file",
    "浏览": "Browse",

    // ---- 托盘菜单 ----
    "打开面板": "Open Panel",

    // ---- 小猫文案（彩蛋） ----
    "Git commit -m '又一个 Bug' 🔧": "git commit -m 'yet another bug' 🔧",
    "产品经理说很简单 🤡": "\"It's simple,\" said the PM 🤡",
    "今天不出 Bug，明天出什么 🎯": "No bugs today? Tomorrow then 🎯",
    "今天也是充满 Bug 的一天 🐛": "Another day full of bugs 🐛",
    "今天也要加油写 Bug 哦 ✨": "Keep shipping bugs ✨",
    "今天的需求明天再做 🌙": "Today's ticket, tomorrow's problem 🌙",
    "代码如诗，Bug 如风 🌸": "Code is poetry, bugs are wind 🌸",
    "代码能跑就行 🏃": "It compiles, ship it 🏃",
    "先实现，再优化（永远不优化）⏳": "Make it work, optimize never ⏳",
    "写代码不如谈恋爱 💕": "Touch grass > touch keyboard 💕",
    "写代码使我快乐（并不）🎭": "Coding sparks joy (no) 🎭",
    "技术债也是债 💸": "Tech debt is still debt 💸",
    "测试？什么测试？ 🎲": "Tests? What tests? 🎲",
    "标题 30 秒快照 vs 弹窗实时查": "title 30s snapshot vs live query",
    "每天一个 key": "one key per day",
    "这个功能很简单的 🎪": "This feature is simple 🎪",
    "这个接口我三分钟就写完 ⚡": "Three-minute API ⚡",
    "这个需求一天就能做完 📝": "One-day task, for sure 📝",
    "码农的一天从咖啡开始 ☕": "Dev day starts with coffee ☕",
    "线上出 Bug 了？不可能 🚫": "Prod bug? Impossible 🚫",
    "重构？先加个 if 吧 🤔": "Refactor? Just add an if 🤔",
    "需求又改了，习惯就好 🫠": "Specs changed again, classic 🫠",
]
