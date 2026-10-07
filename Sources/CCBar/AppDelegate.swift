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

    /// 菜单栏动画伴侣
    let petController = MenuPetController()
    /// 上次刷新的今日总量（闪电 LED 变色依据）
    private var lastLEDTotal: Int64?

    var settingsWindow: SettingsWindowController?
    var detailWindow: DetailWindowController?
    var insightsWindow: InsightsWindowController?
    var monthWindow: MonthDetailWindowController?
    var hourlyWindow: HourlyDetailWindowController?
    var modelWindow: ModelDetailWindowController?
    var allTimeWindow: AllTimeDetailWindowController?

    // MARK: - 里程碑动画
    var bubbleWindows: [NSWindow] = []

    // 随机问候语
    let greetings = [
        "今天也要加油写 Bug 哦 ✨",
        L("代码如诗，Bug 如风 🌸"),
        L("写代码不如谈恋爱 💕"),
        L("需求又改了，习惯就好 🫠"),
        L("今天不出 Bug，明天出什么 🎯"),
        L("写代码使我快乐（并不）🎭"),
        L("技术债也是债 💸"),
        L("今天的需求明天再做 🌙"),
        L("码农的一天从咖啡开始 ☕"),
        L("Git commit -m '又一个 Bug' 🔧"),
        L("产品经理说很简单 🤡"),
        L("这个需求一天就能做完 📝"),
        L("代码能跑就行 🏃"),
        L("今天也是充满 Bug 的一天 🐛"),
        L("先实现，再优化（永远不优化）⏳"),
        L("这个接口我三分钟就写完 ⚡"),
        L("测试？什么测试？ 🎲"),
        L("线上出 Bug 了？不可能 🚫"),
        L("重构？先加个 if 吧 🤔"),
        L("这个功能很简单的 🎪")
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        pruneDailyUserDefaults()

        // 初始数据库连接（自建统计库 + ATTACH 各数据源）
        connectDB()

        // 左键弹面板，右键快捷菜单
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildStatusBarChrome()

        setupNotifications()

        // 初始更新
        updateData()

        // 定时器
        startTimer()

        // 每日家务：自动备份 + 静默检查更新
        runDailyHousekeeping()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.openInsights()
        }
    }

    /// 每日家务（全部静默，失败只打日志不打扰）：
    /// - 统计库自动备份到 ~/Library/Application Support/ccbar/backups，滚动保留最近 7 份
    /// - 每 3 天静默检查一次更新，有新版才弹提示
    func runDailyHousekeeping() {
        let defaults = UserDefaults.standard
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)

        if defaults.string(forKey: "lastAutoBackupDate") != today {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ccbar/backups", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("ccbar-auto-\(today).db").path
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, self.store.backup(to: target) else { return }
                defaults.set(today, forKey: "lastAutoBackupDate")
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                    .filter { $0.hasPrefix("ccbar-auto-") && $0.hasSuffix(".db") }
                    .sorted() ?? []
                for old in files.dropLast(7) {
                    try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(old).path)
                }
            }
        }

        // 每周一生成上周用量周报（幂等键 = 周一日期，静默）；卡片渲染需回主线程
        Task { @MainActor in WeeklyReport.generateIfNeeded(store: store) }

        if let last = defaults.object(forKey: "lastUpdateCheckDate") as? Date,
           Date().timeIntervalSince(last) < 3 * 24 * 3600 {
            return
        }
        defaults.set(Date(), forKey: "lastUpdateCheckDate")
        UpdateChecker.check(silent: true)
    }

    /// 菜单栏小闪电图标。
    /// fill 为 nil 时渲染模板单色（系统自适应深浅菜单栏，观感与系统图标一致）；
    /// 给定颜色时表示活动状态（绿=有消耗，红=大增量），带描边保证两种菜单栏可见。
    static func makeMenuBarIcon(fill: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 9.5, y: 15))
        path.line(to: NSPoint(x: 5, y: 8))
        path.line(to: NSPoint(x: 7.5, y: 8))
        path.line(to: NSPoint(x: 6.5, y: 1))
        path.line(to: NSPoint(x: 11, y: 8.5))
        path.line(to: NSPoint(x: 8.5, y: 8.5))
        path.close()
        if let fill = fill {
            fill.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.8
            path.stroke()
            image.isTemplate = false
        } else {
            NSColor.black.setFill()
            path.fill()
            image.isTemplate = true
        }
        image.unlockFocus()
        return image
    }

    /// 依据设置装配菜单栏外观：动画伴侣（小猫）或静态闪电图标
    func rebuildStatusBarChrome() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        if settings.menuPetEnabled {
            petController.attach(to: button)
        } else {
            petController.detach()
            button.image = Self.makeMenuBarIcon()
            lastLEDTotal = nil
        }
    }

    /// 预警阈值进度（0~1.6，超阈值继续增长供表情/动画分级）
    private func thresholdProgress(total: Int64) -> Double {
        let denom = settings.warningThreshold > 0 ? Double(settings.warningThreshold) * 10_000 : 100_000_000
        return min(Double(total) / denom, 1.6)
    }

    @objc func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// 右键快捷菜单（弹窗之外的常规出口：详情/设置/复制/退出）
    private func showContextMenu() {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            (L("洞察中心"), #selector(openInsights)),
            (L("今日详情"), #selector(openHourlyDetailToday)),
            (L("近7天用量"), #selector(openDetail)),
            (L("历史总量"), #selector(openAllTimeDetail)),
            (L("复制今日统计"), #selector(copyStats)),
            (L("设置"), #selector(openSettings)),
            (L("退出"), #selector(quit)),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // 在按钮位置弹出菜单
        statusItem.menu = nil                  // 弹完移除，左键行为不受影响
    }

    // MARK: - Popover

    var popover: NSPopover?
    var eventMonitor: Any?
    /// ESC 关闭弹窗（popover 非 key window，收不到 keyDown，用本地事件监视器实现）
    var keyMonitor: Any?

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
            popover.contentSize = NSSize(width: settings.popoverWide ? 380 : 300, height: 500)
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.delegate = self
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.contentViewController = PopoverViewController()
            self.popover = popover
        }

        // 每次打开重新抽一句问候语
        if let vc = popover?.contentViewController as? PopoverViewController {
            vc.rollGreeting()
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
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53, self?.popover?.isShown == true {   // ESC
                    self?.closePopover()
                    return nil
                }
                return event
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
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // popover 与其 contentViewController 复用，不随关闭销毁
    func popoverDidClose(_ notification: Notification) {
        removeEventMonitor()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        return true
    }

    // MARK: - Database

    func connectDB() {
        queryQueue.async { [weak self] in
            guard let self = self else { return }
            self.store.rebuild(configs: self.settings.sourceConfigs)
            if self.store.handle == nil {
                print("[ccBar] 统计库打开失败")
            }
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

                // 每日家务顺带跑一遍（内部全部幂等早退，保证长开不重启也能赶上周一出周报）
                self.runDailyHousekeeping()

                // 菜单栏悬停摘要
                var tip = String(format: L("今日：%@"), todayStats.map { Design.formatTokens($0.total) } ?? "-")
                if let y = DataCache.shared.getCachedYesterday() { tip += String(format: L("\n昨日：%@"), Design.formatTokens(y.total)) }
                if let t = todayStats { tip += String(format: L("\n请求数：%d"), t.reqs) }
                self.statusItem.button?.toolTip = tip

                if let stats = todayStats {
                    // 闪电 LED：对比上次刷新的增量变色（仅关闭动画伴侣时显示图标）
                    // 无变化 → 模板单色（系统自适应）；有消耗 → 绿；达红色门槛 → 红
                    if !self.settings.menuPetEnabled {
                        let fill: NSColor?
                        if let last = self.lastLEDTotal {
                            let delta = stats.total - last
                            let redLine = Int64(max(self.settings.ledRedThreshold, 0)) * 10_000
                            if redLine > 0 && delta >= redLine { fill = .systemRed }
                            else if delta > 0 { fill = .systemGreen }
                            else { fill = nil }
                        } else {
                            fill = nil
                        }
                        self.statusItem.button?.image = Self.makeMenuBarIcon(fill: fill)
                    }
                    self.lastLEDTotal = stats.total
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

    // 数字滚动动画状态
    private var displayedTotal: Int64 = -1
    private var rollTimer: Timer?
    private var rollFrom: Int64 = 0
    private var rollTo: Int64 = 0
    private var rollStart = Date()

    /// 标题全文（表情分级 + 数字）
    private func titleText(for total: Int64) -> String {
        var text = fmtTitle(total)
        if settings.menuEmojiEnabled {
            text = PetPose.emoji(progress: thresholdProgress(total: total)) + " " + text
        }
        return text
    }

    private func setMenuTitle(text: String, color: NSColor?) {
        var attrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        if let color = color {
            attrs[.foregroundColor] = color
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func cancelRoll() {
        rollTimer?.invalidate()
        rollTimer = nil
    }

    /// 用统计结果更新菜单栏标题：数值变化时从旧值滚动到新值（0.7s 缓出），并同步宠物状态
    func applyTitle(_ stats: DayStats?) {
        guard let button = statusItem.button else { return }
        guard let stats = stats else {
            cancelRoll()
            displayedTotal = -1
            button.attributedTitle = NSAttributedString(
                string: store.attachedAdapters.isEmpty ? L("未启用") : L("未找到"),
                attributes: [.font: titleFont])
            return
        }
        let progress = thresholdProgress(total: stats.total)
        let color = titleColor(for: stats.total)

        if stats.total == displayedTotal {
            setMenuTitle(text: titleText(for: stats.total), color: color)
            petController.refresh(progress: progress)
            return
        }

        // 滚动动画：displayedTotal 在启动时就指向目标，重复调用不会重启动画
        let previous = max(displayedTotal, 0)
        displayedTotal = stats.total
        rollFrom = previous
        rollTo = stats.total
        rollStart = Date()
        cancelRoll()
        rollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.rollTick()
        }
        RunLoop.main.add(rollTimer!, forMode: .common)
        rollTick()
        petController.refresh(progress: progress)
    }

    private func rollTick() {
        let t = min(Date().timeIntervalSince(rollStart) / 0.7, 1)
        let eased = 1 - pow(1 - t, 3)   // easeOutCubic
        let value = Int64((Double(rollFrom) + Double(rollTo - rollFrom) * eased).rounded())
        setMenuTitle(text: titleText(for: value), color: titleColor(for: rollTo))
        if t >= 1 {
            cancelRoll()
        }
    }

    /// 菜单栏标题颜色：按预警阈值进度渐变（绿→黄→橙→红），与用户设置的预警阈值联动。
    /// 阈值为 0（关闭预警）时返回 nil → 用系统默认色。
    func titleColor(for total: Int64) -> NSColor? {
        guard settings.warningThreshold > 0 else { return nil }
        return Design.usageColor(total: total, thresholdWan: settings.warningThreshold)
    }

    /// 立即刷新菜单栏标题（不依赖定时器）
    func refreshTitleColor() {
        applyTitle(DataCache.shared.getCachedToday())
    }

    func flashTitle() {
        guard let button = statusItem.button else { return }
        cancelRoll()   // 闪烁期间停止数字滚动，避免互相覆盖

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
        // 周报通知的「打开周报目录」按钮
        let openFolder = UNNotificationAction(identifier: "OPEN_WEEKLY_FOLDER", title: L("打开周报目录"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "CCBAR_WEEKLY", actions: [openFolder], intentIdentifiers: [])
        ])
    }

    func sendNotification(title: String, body: String, identifier: String = "ccbar.notice", category: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category {
            content.categoryIdentifier = category
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// 点击通知：预警 → 打开设置调阈值；里程碑 → 打开面板
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            // 周报通知上的「打开周报目录」按钮
            if action == "OPEN_WEEKLY_FOLDER" {
                let dir = WeeklyReport.directoryURL()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
                completionHandler()
                return
            }
            if id.hasPrefix("ccbar.warning") {
                self?.openSettings()
            } else if id.hasPrefix("ccbar.weekly") {
                self?.openInsights()
            } else {
                self?.showPopover()
            }
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
            sendNotification(title: L("用量预警"),
                             body: String(format: L("今日 Token 用量已达 %@，超过预警阈值 %d万"),
                                          fmtK(stats.total), settings.warningThreshold),
                             identifier: "ccbar.warning")
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

        sendNotification(title: L("🎉 用量里程碑"),
                         body: String(format: L("今日 Token 已达 %@（每%d万通知一次）"),
                                      fmtK(total), intervalWan),
                         identifier: "ccbar.milestone")
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
        L10n.formatTokens(n)
    }

    func fmtTitle(_ n: Int64) -> String {
        return Design.formatTokens(n)
    }

    @objc func copyStats() {
        var text = L("ccBar 今日用量统计\n")
        text += "==================\n"

        if let stats = DataCache.shared.getCachedToday() {
            text += String(format: L("Token 总量: %@\n"), fmtK(stats.total))
            text += String(format: L("请求数量: %d\n"), stats.reqs)
            text += String(format: L("输入 Token: %@\n"), fmtK(stats.input))
            text += String(format: L("输出 Token: %@\n"), fmtK(stats.output))
        }

        let sources = store.querySourceBreakdown()
        if sources.count > 1 {
            text += L("\n数据源分布:\n")
            for s in sources {
                text += "  \(sourceDisplayName(s.source)): \(fmtK(s.total))\n"
            }
        }

        if let models = DataCache.shared.getCachedModelBreakdown() {
            text += L("\n模型分布:\n")
            for model in models {
                text += "  \(model.model): \(fmtK(model.total))\n"
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        closePopover()

        let alert = NSAlert()
        alert.messageText = L("已复制到剪贴板")
        alert.informativeText = L("统计数据已复制，可直接粘贴使用")
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
                // 伴侣/表情开关、主题切换立即生效
                self?.rebuildStatusBarChrome()
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

    /// 洞察中心（费用 / 洞察 / 分享 / 渠道 / 流水）
    @objc func openInsights() {
        closePopover()
        if insightsWindow == nil {
            insightsWindow = InsightsWindowController()
        }
        insightsWindow?.reload()
        insightsWindow?.showWindow(nil)
        insightsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        monthWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 历史总量（按月汇总）
    @objc func openAllTimeDetail() {
        closePopover()
        if allTimeWindow == nil {
            allTimeWindow = AllTimeDetailWindowController()
        }
        allTimeWindow?.reloadData(db: db, today: store.queryDayStats(days: 0))
        allTimeWindow?.showWindow(nil)
        allTimeWindow?.window?.makeKeyAndOrderFront(nil)
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
