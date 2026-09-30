import Cocoa
import SQLite3

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var timer: Timer?
    let settings = Settings()
    var settingsWindow: SettingsWindowController?
    var detailWindow: DetailWindowController?
    var monthWindow: MonthDetailWindowController?
    var hourlyWindow: HourlyDetailWindowController?
    var modelWindow: ModelDetailWindowController?
    var lastNotificationDate: Date?
    var currentHourlyDate: Date?

    // MARK: - 里程碑动画
    var lastTokenTier: Int = 0
    var bubbleWindows: [NSWindow] = []

    // 随机问候语
    let greetings = [
        "今天也要加油写 Bug 哦 ✨",
        "代码如诗，Bug 如风 🌸",
        "写代码不如谈恋爱 💕",
        "需求又改了，习惯就好 🫠",
        "今天不出 Bug，明天出什么 🎯",
        "写代码使我快乐（并不）🎭",
        "技术债也是债 💸",
        "今天的需求明天再做 🌙",
        "码农的一天从咖啡开始 ☕",
        "Git commit -m '又一个 Bug' 🔧",
        "产品经理说很简单 🤡",
        "这个需求一天就能做完 📝",
        "代码能跑就行 🏃",
        "今天也是充满 Bug 的一天 🐛",
        "先实现，再优化（永远不优化）⏳",
        "这个接口我三分钟就写完 ⚡",
        "测试？什么测试？ 🎲",
        "线上出 Bug 了？不可能 🚫",
        "重构？先加个 if 吧 🤔",
        "这个功能很简单的 🎪"
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 不设置菜单栏图标，只显示数字

        // 初始数据库连接（自建统计库 + ATTACH 各数据源）
        connectDB()

        // 设置点击事件（使用 popover 替代 menu）
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // 初始更新
        updateData()

        // 定时器
        startTimer()

    }

    var popover: NSPopover?
    var eventMonitor: Any?

    @objc func togglePopover() {
        if let popover = popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        if popover == nil {
            let popover = NSPopover()
            popover.contentSize = NSSize(width: 300, height: 500)
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.delegate = self
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.contentViewController = PopoverViewController()
            self.popover = popover
        }

        if let button = statusItem.button {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        // 打开弹窗时做一次实时查询，并把结果同步到菜单栏标题，
        // 消除"标题 30 秒快照 vs 弹窗实时查"的数字时差
        refreshData()

        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let popover = self?.popover, popover.isShown {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover?.performClose(nil)
        removeEventMonitor()
    }

    func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        removeEventMonitor()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        return true
    }

    // MARK: - Database

    let store = StatsStore()
    /// 统计库连接（= store.handle，含 ATTACH 的各数据源），详情窗口共用
    var db: OpaquePointer? {
        return store.handle
    }

    func connectDB() {
        store.rebuild(configs: settings.sourceConfigs)
        if store.handle == nil {
            print("无法打开统计库")
        }
    }

    // MARK: - Timer

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: TimeInterval(settings.refreshInterval),
                                     target: self,
                                     selector: #selector(updateData),
                                     userInfo: nil,
                                     repeats: true)
    }

    @objc func updateData() {
        // 懒惰补账：历史（昨天及更早）落后就同步进自建库，今日走实时查询
        store.syncIfNeeded()

        let todayStats = queryDayStats(days: 0)

        var modelBreakdown: [(model: String, input: Int64, output: Int64, total: Int64)]?
        if DataCache.shared.needsModelCache() {
            modelBreakdown = queryModelBreakdown()
            DataCache.shared.markModelCacheDone()
        }

        var yesterdayStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
        var weekStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
        var monthStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
        var totalStats: (reqs: Int, total: Int64)?

        if DataCache.shared.needsDailyCache() {
            yesterdayStats = queryDayStats(days: 1)
            weekStats = queryDayStats(days: 7)
            monthStats = queryDayStats(days: 30)
            totalStats = queryTotalStats()
            DataCache.shared.markDailyCacheDone()
        }

        DataCache.shared.update(
            today: todayStats,
            yesterday: yesterdayStats,
            week: weekStats,
            month: monthStats,
            total: totalStats,
            models: modelBreakdown
        )

        if let stats = todayStats {
            let totalStr = fmtTitle(stats.total)
            let color = titleColor(for: stats.total)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ]
            statusItem.button?.attributedTitle = NSAttributedString(string: totalStr, attributes: attrs)

            checkWarning(stats: stats)
            checkTokenMilestone(stats.total)
        } else {
            statusItem.button?.title = store.attachedAdapters.isEmpty ? "未启用" : "未找到"
        }

        // 图标由 updateIcon 设置，此处不覆盖

        // 如果弹窗正在显示，刷新内容（确保主题切换后立即生效）
        if let popover = popover, popover.isShown,
           let vc = popover.contentViewController as? PopoverViewController {
            vc.refresh()
        }
    }

    // MARK: - Query Methods

    func queryDayStats(days: Int) -> (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)? {
        guard let db = db, !store.attachedAdapters.isEmpty else { return nil }

        var stmt: OpaquePointer?
        let sql: String
        var bindDays: Int?

        if days == 0 {
            // 今日：用 date() 函数匹配，避免时区问题
            sql = """
            SELECT
                COALESCE(SUM(request_count), 0) as reqs,
                COALESCE(SUM(input_tokens), 0) as input,
                COALESCE(SUM(output_tokens), 0) as output,
                COALESCE(SUM(cache_creation_tokens), 0) as cache_create,
                COALESCE(SUM(cache_read_tokens), 0) as cache_read
            FROM usage_all
            WHERE date(created_at, 'unixepoch', 'localtime') = date('now', 'localtime')
            """
        } else if days == 1 {
            // 昨日
            sql = """
            SELECT
                COALESCE(SUM(request_count), 0) as reqs,
                COALESCE(SUM(input_tokens), 0) as input,
                COALESCE(SUM(output_tokens), 0) as output,
                COALESCE(SUM(cache_creation_tokens), 0) as cache_create,
                COALESCE(SUM(cache_read_tokens), 0) as cache_read
            FROM usage_all
            WHERE date(created_at, 'unixepoch', 'localtime') = date('now', 'localtime', '-1 day')
            """
        } else {
            // 近N天
            sql = """
            SELECT
                COALESCE(SUM(request_count), 0) as reqs,
                COALESCE(SUM(input_tokens), 0) as input,
                COALESCE(SUM(output_tokens), 0) as output,
                COALESCE(SUM(cache_creation_tokens), 0) as cache_create,
                COALESCE(SUM(cache_read_tokens), 0) as cache_read
            FROM usage_all
            WHERE date(created_at, 'unixepoch', 'localtime') >= date('now', 'localtime', '-\(days) days')
            """
        }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }

        var result: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?

        if sqlite3_step(stmt) == SQLITE_ROW {
            let reqs = Int(sqlite3_column_int(stmt, 0))
            let input = sqlite3_column_int64(stmt, 1)
            let output = sqlite3_column_int64(stmt, 2)
            let cacheCreate = sqlite3_column_int64(stmt, 3)
            let cacheRead = sqlite3_column_int64(stmt, 4)
            let total = input + output + cacheCreate + cacheRead
            result = (reqs, input, output, cacheCreate, cacheRead, total)
        }

        sqlite3_finalize(stmt)
        return result
    }

    func queryModelBreakdown() -> [(model: String, input: Int64, output: Int64, total: Int64)]? {
        guard let db = db else { return nil }

        var stmt: OpaquePointer?
        let sql = """
        SELECT
            model,
            COALESCE(SUM(input_tokens), 0) as input,
            COALESCE(SUM(output_tokens), 0) as output,
            COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0) as total
        FROM usage_all
        WHERE date(created_at, 'unixepoch', 'localtime') = date('now', 'localtime')
        GROUP BY model
        ORDER BY total DESC
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }

        var result: [(model: String, input: Int64, output: Int64, total: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let input = sqlite3_column_int64(stmt, 1)
            let output = sqlite3_column_int64(stmt, 2)
            let total = sqlite3_column_int64(stmt, 3)
            result.append((model, input, output, total))
        }
        sqlite3_finalize(stmt)
        return result
    }

    func queryWorkHours() -> String? {
        guard let db = db else { return nil }

        var stmt: OpaquePointer?
        let sql = """
        SELECT MIN(created_at)
        FROM usage_all
        WHERE date(created_at, 'unixepoch', 'localtime') = date('now', 'localtime')
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = sqlite3_column_int64(stmt, 0)
            let startDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let hours = Date().timeIntervalSince(startDate) / 3600
            sqlite3_finalize(stmt)
            return String(format: "%.1f", hours)
        }
        sqlite3_finalize(stmt)
        return nil
    }

    func queryTotalStats() -> (reqs: Int, total: Int64)? {
        guard let db = db, !store.attachedAdapters.isEmpty else { return nil }

        var stmt: OpaquePointer?
        // 历史聚合已在补账时展开进 usage_log，明细 + 今日实时全在 usage_all 里，单表即全量
        let sql = """
        SELECT COALESCE(SUM(request_count), 0),
            COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let reqs = Int(sqlite3_column_int(stmt, 0))
            let total = sqlite3_column_int64(stmt, 1)
            sqlite3_finalize(stmt)
            return (reqs, total)
        }
        sqlite3_finalize(stmt)
        return nil
    }

    /// 今日各数据源分账（source, 请求数, token 总量）
    func querySourceBreakdown() -> [(source: String, reqs: Int, total: Int64)] {
        guard let db = db, !store.attachedAdapters.isEmpty else { return [] }

        var stmt: OpaquePointer?
        let sql = """
        SELECT source, COALESCE(SUM(request_count), 0),
            COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all
        WHERE date(created_at, 'unixepoch', 'localtime') = date('now', 'localtime')
        GROUP BY source
        ORDER BY 3 DESC
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var result: [(String, Int, Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = String(cString: sqlite3_column_text(stmt, 0))
            result.append((source, Int(sqlite3_column_int(stmt, 1)), sqlite3_column_int64(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        return result
    }

    func queryDailyBreakdown(days: Int) -> [(date: String, reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, cost: Double)]? {
        guard let db = db else { return nil }

        var stmt: OpaquePointer?
        let sql = """
        SELECT
            date(created_at, 'unixepoch', 'localtime') as date,
            COALESCE(SUM(request_count), 0) as reqs,
            COALESCE(SUM(input_tokens), 0) as input,
            COALESCE(SUM(output_tokens), 0) as output,
            COALESCE(SUM(cache_creation_tokens), 0) as cache_create,
            COALESCE(SUM(cache_read_tokens), 0) as cache_read,
            COALESCE(SUM(CAST(total_cost_usd AS REAL)), 0) as cost
        FROM usage_all
        WHERE created_at >= strftime('%s', 'now', 'localtime', '-' || ? || ' days')
        GROUP BY date
        ORDER BY date DESC
        """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_int(stmt, 1, Int32(days))

        var result: [(date: String, reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, cost: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = String(cString: sqlite3_column_text(stmt, 0))
            let reqs = Int(sqlite3_column_int(stmt, 1))
            let input = sqlite3_column_int64(stmt, 2)
            let output = sqlite3_column_int64(stmt, 3)
            let cacheCreate = sqlite3_column_int64(stmt, 4)
            let cacheRead = sqlite3_column_int64(stmt, 5)
            let cost = sqlite3_column_double(stmt, 6)
            result.append((date, reqs, input, output, cacheCreate, cacheRead, cost))
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Warning & Milestone

    func checkWarning(stats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)) {
        guard settings.warningEnabled else { return }

        let todayKey = "warningNotified_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none))"
        if UserDefaults.standard.bool(forKey: todayKey) {
            return
        }

        let thresholdInTokens = Int64(settings.warningThreshold) * 10000
        if stats.total >= thresholdInTokens {
            sendNotification(total: stats.total, threshold: thresholdInTokens)
            UserDefaults.standard.set(true, forKey: todayKey)
        }
    }

    func sendNotification(total: Int64, threshold: Int64) {
        let notification = NSUserNotification()
        notification.title = "用量预警"
        notification.informativeText = "今日 Token 用量已达 \(fmtK(total))，超过预警阈值 \(settings.warningThreshold)万"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - 里程碑动画

    /// 按设定间隔触发通知（每 N 万弹一次，每个档位每天只通知一次）
    func checkTokenMilestone(_ total: Int64) {
        let intervalWan = settings.notifyInterval
        guard intervalWan > 0 else { return }
        let interval = Int64(intervalWan) * 10_000
        let tier = Int(total / interval)
        guard tier > 0 else { return }

        // 每个档位每天只通知一次（持久化记录）
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let key = "milestone_\(today)_\(tier)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        // 记录已通知，不再重复
        UserDefaults.standard.set(true, forKey: key)

        let deltaTokens = total % interval == 0 ? interval : total - Int64(tier - 1) * interval

        showBubble(delta: deltaTokens)
        flashTitle()

        // 发送系统通知
        let notification = NSUserNotification()
        notification.title = "🎉 用量里程碑"
        notification.informativeText = "今日 Token 已达 \(fmtK(total))（每\(intervalWan)万通知一次）"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    func showBubble(delta: Int64) {
        guard let button = statusItem.button, let window = button.window else { return }

        let text = "🫧 +\(fmtK(delta))"

        let bubbleW: CGFloat = 100
        let bubbleH: CGFloat = 32
        let bubble = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: bubbleW, height: bubbleH),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = false
        bubble.ignoresMouseEvents = true
        bubble.level = .floating

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        label.textColor = Design.brandColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: bubbleW, height: bubbleH)

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: bubbleW, height: bubbleH))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Design.brandColor.withAlphaComponent(0.18).cgColor
        bg.layer?.cornerRadius = bubbleH / 2

        bg.addSubview(label)
        bubble.contentView = bg

        let btnFrame = window.frame
        bubble.setFrameOrigin(NSPoint(
            x: btnFrame.midX - bubbleW / 2,
            y: btnFrame.minY - bubbleH - 8
        ))
        bubble.alphaValue = 0
        bubble.orderFrontRegardless()

        bubbleWindows.append(bubble)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bubble.animator().alphaValue = 1
            let frame = bubble.frame
            bubble.animator().setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y - 30))
        }, completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    bubble.animator().alphaValue = 0
                    let frame = bubble.frame
                    bubble.animator().setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y - 20))
                }, completionHandler: { [weak self] in
                    bubble.orderOut(nil)
                    self?.bubbleWindows.removeAll { $0 === bubble }
                })
            }
        })
    }

    func flashTitle() {
        guard let button = statusItem.button else { return }

        let currentText = button.attributedTitle.string.isEmpty
            ? button.title
            : button.attributedTitle.string

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Design.brandColor,
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        ]
        button.attributedTitle = NSAttributedString(string: "✨ " + currentText, attributes: attrs)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if let stats = DataCache.shared.getCachedToday() {
                let color = self.titleColor(for: stats.total)
                let normalAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: color,
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                ]
                button.attributedTitle = NSAttributedString(string: self.fmtTitle(stats.total), attributes: normalAttrs)
            } else {
                let fallback: [NSAttributedString.Key: Any] = [
                    .foregroundColor: Design.textPrimary,
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                ]
                button.attributedTitle = NSAttributedString(string: currentText, attributes: fallback)
            }
        }
    }

    func updateIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if let button = statusItem.button {
            if isDark {
                button.image = createIcon(color: NSColor.white)
            } else {
                button.image = createIcon(color: NSColor.black)
            }
        }
    }

    func createIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        let ctx = NSGraphicsContext.current!
        ctx.cgContext.setFillColor(color.cgColor)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 10, y: 18))
        path.line(to: NSPoint(x: 6, y: 10))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 2))
        path.line(to: NSPoint(x: 12, y: 10))
        path.line(to: NSPoint(x: 9, y: 10))
        path.close()
        path.fill()

        image.unlockFocus()
        image.isTemplate = true

        return image
    }

    func updateMenu() {
        if let popover = popover, popover.isShown,
           let vc = popover.contentViewController as? PopoverViewController {
            vc.refresh()
        }
    }

    @objc func refreshData() {
        let todayStats = queryDayStats(days: 0)
        let modelBreakdown = queryModelBreakdown()

        DataCache.shared.update(
            today: todayStats,
            yesterday: nil,
            week: nil,
            month: nil,
            total: nil,
            models: modelBreakdown
        )

        if let stats = todayStats {
            let totalStr = fmtTitle(stats.total)
            let color = titleColor(for: stats.total)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ]
            statusItem.button?.attributedTitle = NSAttributedString(string: totalStr, attributes: attrs)
        }

        updateMenu()
    }

    func fmtK(_ n: Int64) -> String {
        if n >= 100_000_000 {
            let d = Double(n) / 100_000_000
            return String(format: "%.2f亿", d)
        } else if n >= 10_000 {
            let w = n / 10_000
            return "\(w)万"
        } else {
            return "\(n)"
        }
    }

    func fmtTitle(_ n: Int64) -> String {
        return Design.formatTokens(n)
    }

    func fmtTotal(_ n: Int64) -> String {
        if n >= 100_000_000 {
            let d = Double(n) / 100_000_000
            return String(format: "%.2f亿", d)
        } else {
            return fmtK(n)
        }
    }

    @objc func copyStats() {
        var text = "ccBar 今日用量统计\n"
        text += "==================\n"

        if let stats = DataCache.shared.getCachedToday() {
            text += "Token 总量: \(fmtK(stats.total))\n"
            text += "请求数量: \(stats.reqs)\n"
            text += "输入 Token: \(fmtK(stats.input))\n"
            text += "输出 Token: \(fmtK(stats.output))\n"
        }

        let sources = querySourceBreakdown()
        if sources.count > 1 {
            text += "\n数据源分布:\n"
            for s in sources {
                text += "  \(sourceDisplayName(s.source)): \(fmtK(s.total))\n"
            }
        }

        if let models = DataCache.shared.getCachedModelBreakdown() {
            text += "\n模型分布:\n"
            for model in models {
                text += "  \(model.model): \(fmtK(model.total))\n"
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        closePopover()

        let alert = NSAlert()
        alert.messageText = "已复制到剪贴板"
        alert.informativeText = "统计数据已复制，可直接粘贴使用"
        alert.runModal()
    }

    /// source 标识 → 界面显示名（历史聚合行归入 cc-switch）
    func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "zcode": return "ZCode"
        case "cc-switch", "cc-switch-rollup": return "cc-switch"
        default: return source
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in
                self?.connectDB()
                self?.startTimer()
                self?.updateData()
                // 主题切换后强制刷新标题颜色（不等定时器）
                self?.refreshTitleColor()
            }
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单栏标题颜色（按总量阈值分级）
    func titleColor(for total: Int64) -> NSColor {
        if total >= 200_000_000 {       // ≥2亿  深红
            return NSColor(red: 0.90, green: 0.22, blue: 0.25, alpha: 1.0)
        } else if total >= 150_000_000 { // ≥1.5亿 浅红
            return NSColor(red: 0.95, green: 0.45, blue: 0.40, alpha: 1.0)
        } else if total >= 100_000_000 { // ≥1亿  深绿
            return NSColor(red: 0.15, green: 0.72, blue: 0.40, alpha: 1.0)
        } else if total >= 50_000_000 {  // ≥5000万 浅绿
            return NSColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0)
        } else {                         // <5000万 白色
            return NSColor.white
        }
    }

    /// 立即刷新菜单栏标题颜色（不依赖定时器）
    func refreshTitleColor() {
        guard let stats = DataCache.shared.getCachedToday() else { return }
        let totalStr = fmtTitle(stats.total)
        let color = titleColor(for: stats.total)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: totalStr, attributes: attrs)
    }

    @objc func openSettingsAndClose() {
        closePopover()
        openSettings()
    }

    @objc func openDetail() {
        closePopover()
        print("[ccBar] openDetail called, db=\(db != nil ? "ok" : "nil")")
        if detailWindow == nil {
            detailWindow = DetailWindowController()
            detailWindow?.onDateChange = { [weak self] newWeekStart in
                self?.openWeekDetail(for: newWeekStart)
            }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -(weekday - 2), to: today)!
        detailWindow?.reloadData(db: db, weekStart: weekStart)
        detailWindow?.showWindow(nil)
        detailWindow?.window?.center()
        detailWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[ccBar] detailWindow shown: \(detailWindow?.window?.isVisible ?? false)")
    }

    func openWeekDetail(for weekStart: Date) {
        if detailWindow == nil {
            detailWindow = DetailWindowController()
            detailWindow?.onDateChange = { [weak self] newWeekStart in
                self?.openWeekDetail(for: newWeekStart)
            }
        }
        detailWindow?.reloadData(db: db, weekStart: weekStart)
        detailWindow?.showWindow(nil)
        detailWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openMonthDetail() {
        closePopover()
        if monthWindow == nil {
            monthWindow = MonthDetailWindowController()
        }
        monthWindow?.db = db
        monthWindow?.currentMonth = Date()
        monthWindow?.reloadData()
        monthWindow?.showWindow(nil)
        monthWindow?.window?.center()
        monthWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openModelDetail(for date: Date) {
        closePopover()
        if modelWindow == nil {
            modelWindow = ModelDetailWindowController()
            modelWindow?.onDateChange = { [weak self] newDate in
                self?.openModelDetail(for: newDate)
            }
        }
        modelWindow?.db = db
        modelWindow?.reloadData(db: db, date: date)
        modelWindow?.showWindow(nil)
        modelWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openModelDetailToday() {
        openModelDetail(for: Date())
    }

    func openHourlyDetail(for date: Date) {
        closePopover()
        if hourlyWindow == nil {
            hourlyWindow = HourlyDetailWindowController()
            hourlyWindow?.onDateChange = { [weak self] newDate in
                self?.openHourlyDetail(for: newDate)
            }
        }
        currentHourlyDate = date
        hourlyWindow?.reloadData(db: db, date: date)
        hourlyWindow?.showWindow(nil)
        hourlyWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openHourlyDetailToday() {
        openHourlyDetail(for: Date())
    }

    @objc func openHourlyDetailYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        openHourlyDetail(for: yesterday)
    }

    @objc func quit() {
        closePopover()
        NSApp.terminate(nil)
    }
}
