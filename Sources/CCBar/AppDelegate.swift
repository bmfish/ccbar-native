import Cocoa
import SQLite3
import UserNotifications

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var timer: Timer?
    let settings = Settings()
    let store = StatsStore()
    /// 统计库连接（= store.handle，含 ATTACH 的各数据源），详情窗口共用
    var db: OpaquePointer? {
        return store.handle
    }

    /// 统计库查询/同步都走这条后台串行队列，结果回主线程更新 UI
    private let queryQueue = DispatchQueue(label: "ccbar.query", qos: .utility)

    var settingsWindow: SettingsWindowController?
    var detailWindow: DetailWindowController?
    var monthWindow: MonthDetailWindowController?
    var hourlyWindow: HourlyDetailWindowController?
    var modelWindow: ModelDetailWindowController?

    // MARK: - 里程碑动画
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

        pruneDailyUserDefaults()

        // 初始数据库连接（自建统计库 + ATTACH 各数据源）
        connectDB()

        // 设置点击事件（使用 popover 替代 menu）
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        setupNotifications()

        // 初始更新
        updateData()

        // 定时器
        startTimer()
    }

    // MARK: - Popover

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

    func connectDB() {
        store.rebuild(configs: settings.sourceConfigs)
        if store.handle == nil {
            print("无法打开统计库")
        }
    }

    // MARK: - Timer

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(settings.refreshInterval),
                      target: self,
                      selector: #selector(updateData),
                      userInfo: nil,
                      repeats: true)
        // .common 模式：弹窗/菜单等交互期间定时器照常触发
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 定时刷新：后台队列跑同步与查询，结果回主线程更新缓存与 UI
    @objc func updateData() {
        queryQueue.async { [weak self] in
            guard let self = self else { return }

            // 懒惰补账：历史（昨天及更早）落后就同步进自建库，今日走实时查询
            self.store.syncIfNeeded()

            let todayStats = self.store.queryDayStats(days: 0)
            let workHours = self.store.queryWorkHours()

            var modelBreakdown: [ModelStat]?
            if DataCache.shared.needsModelCache() {
                modelBreakdown = self.store.queryModelBreakdown()
                DataCache.shared.markModelCacheDone()
            }

            var yesterdayStats: DayStats?
            var weekStats: DayStats?
            var monthStats: DayStats?
            var totalStats: TotalStats?
            if DataCache.shared.needsDailyCache() {
                yesterdayStats = self.store.queryDayStats(days: 1)
                weekStats = self.store.queryDayStats(days: 7)
                monthStats = self.store.queryDayStats(days: 30)
                totalStats = self.store.queryTotalStats()
                DataCache.shared.markDailyCacheDone()
            }

            DispatchQueue.main.async {
                DataCache.shared.update(
                    today: todayStats,
                    yesterday: yesterdayStats,
                    week: weekStats,
                    month: monthStats,
                    total: totalStats,
                    models: modelBreakdown,
                    workHours: workHours
                )
                self.applyTitle(todayStats)

                if let stats = todayStats {
                    self.checkWarning(stats: stats)
                    self.checkTokenMilestone(stats.total)
                }

                // 如果弹窗正在显示，刷新内容（确保主题切换后立即生效）
                if let popover = self.popover, popover.isShown,
                   let vc = popover.contentViewController as? PopoverViewController {
                    vc.refresh()
                }
            }
        }
    }

    /// 打开弹窗/手动刷新：只重查实时性强的今日数据，历史区间走缓存
    @objc func refreshData() {
        queryQueue.async { [weak self] in
            guard let self = self else { return }
            let todayStats = self.store.queryDayStats(days: 0)
            let modelBreakdown = self.store.queryModelBreakdown()
            let workHours = self.store.queryWorkHours()

            DispatchQueue.main.async {
                DataCache.shared.update(
                    today: todayStats,
                    yesterday: nil,
                    week: nil,
                    month: nil,
                    total: nil,
                    models: modelBreakdown,
                    workHours: workHours
                )
                self.applyTitle(todayStats)
                self.updateMenu()
            }
        }
    }

    func updateMenu() {
        if let popover = popover, popover.isShown,
           let vc = popover.contentViewController as? PopoverViewController {
            vc.refresh()
        }
    }

    // MARK: - 菜单栏标题

    private var titleFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    /// 用统计结果更新菜单栏标题；无数据时显示状态文案
    func applyTitle(_ stats: DayStats?) {
        guard let button = statusItem.button else { return }
        guard let stats = stats else {
            button.attributedTitle = NSAttributedString(
                string: store.attachedAdapters.isEmpty ? "未启用" : "未找到",
                attributes: [.font: titleFont])
            return
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        if let color = titleColor(for: stats.total) {
            attrs[.foregroundColor] = color
        }
        button.attributedTitle = NSAttributedString(string: fmtTitle(stats.total), attributes: attrs)
    }

    /// 菜单栏标题颜色（按总量阈值分级）。
    /// 默认档返回 nil → 不设置前景色，用系统默认色，浅色菜单栏下不会隐形。
    func titleColor(for total: Int64) -> NSColor? {
        if total >= 200_000_000 {       // ≥2亿  深红
            return NSColor(red: 0.90, green: 0.22, blue: 0.25, alpha: 1.0)
        } else if total >= 150_000_000 { // ≥1.5亿 浅红
            return NSColor(red: 0.95, green: 0.45, blue: 0.40, alpha: 1.0)
        } else if total >= 100_000_000 { // ≥1亿  深绿
            return NSColor(red: 0.15, green: 0.72, blue: 0.40, alpha: 1.0)
        } else if total >= 50_000_000 {  // ≥5000万 浅绿
            return NSColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0)
        } else {                         // <5000万 系统默认色
            return nil
        }
    }

    /// 立即刷新菜单栏标题（不依赖定时器）
    func refreshTitleColor() {
        applyTitle(DataCache.shared.getCachedToday())
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
            self.applyTitle(DataCache.shared.getCachedToday())
        }
    }

    // MARK: - 通知（UNUserNotificationCenter；NSUserNotification 自 macOS 11 起废弃）

    private func setupNotifications() {
        // UNUserNotificationCenter 只在打包 app 里可用；裸二进制开发运行时跳过
        guard Bundle.main.bundleIdentifier != nil else {
            print("[ccBar] 非打包环境，跳过通知初始化")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[ccBar] 通知授权失败: \(error.localizedDescription)")
            } else if !granted {
                print("[ccBar] 用户未授权通知，用量预警/里程碑将不弹系统通知")
            }
        }
    }

    func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 点击通知 → 打开面板
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
        completionHandler()
    }

    /// App 处于活跃状态时也显示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Warning & Milestone

    func checkWarning(stats: DayStats) {
        guard settings.warningEnabled else { return }

        let todayKey = "warningNotified_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none))"
        if UserDefaults.standard.bool(forKey: todayKey) {
            return
        }

        let thresholdInTokens = Int64(settings.warningThreshold) * 10000
        if stats.total >= thresholdInTokens {
            sendNotification(title: "用量预警",
                             body: "今日 Token 用量已达 \(fmtK(stats.total))，超过预警阈值 \(settings.warningThreshold)万")
            UserDefaults.standard.set(true, forKey: todayKey)
        }
    }

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

        sendNotification(title: "🎉 用量里程碑",
                         body: "今日 Token 已达 \(fmtK(total))（每\(intervalWan)万通知一次）")
    }

    /// 清理"每天一个 key"的历史标记（预警/里程碑），只保留今天的
    private func pruneDailyUserDefaults() {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("milestone_") || key.hasPrefix("warningNotified_") {
            if !key.contains(today) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: - 里程碑动画

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

    @objc func copyStats() {
        var text = "ccBar 今日用量统计\n"
        text += "==================\n"

        if let stats = DataCache.shared.getCachedToday() {
            text += "Token 总量: \(fmtK(stats.total))\n"
            text += "请求数量: \(stats.reqs)\n"
            text += "输入 Token: \(fmtK(stats.input))\n"
            text += "输出 Token: \(fmtK(stats.output))\n"
        }

        let sources = store.querySourceBreakdown()
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
                // 主题切换后立即刷新标题（不等定时器）
                self?.refreshTitleColor()
            }
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettingsAndClose() {
        closePopover()
        openSettings()
    }

    @objc func openDetail() {
        closePopover()
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
