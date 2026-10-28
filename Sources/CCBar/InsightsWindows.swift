import Cocoa
import SwiftUI
import Charts
import CoreImage
import UniformTypeIdentifiers

// MARK: - 洞察中心（费用 / 洞察 / 分享 / 渠道 / 流水）
//
// 一个窗口装五个"钱、复盘、晒图"页面，侧边栏导航。
// 数据全部来自 StatsStore 的洞察查询（epoch 区间走索引，偶发查询无压力）。

// MARK: - 页面定义

enum InsightsPage: String, CaseIterable, Identifiable {
    case insights   = "洞察"
    case credits    = "积分"
    case timeline   = "流水"
    case channels   = "渠道"
    case cost       = "费用"
    case share      = "分享"
    case settings   = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .insights: return "sparkles"
        case .credits: return "bolt.circle"
        case .timeline: return "list.bullet.rectangle"
        case .channels: return "square.stack.3d.up"
        case .cost: return "dollarsign.circle"
        case .share: return "square.and.arrow.up"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - 视图模型

struct ChannelPoint: Identifiable {
    let id = UUID()
    let date: String
    let day: Date
    let source: String
    let name: String
    let token: Int64
}

struct AppPoint: Identifiable {
    let id = UUID()
    let date: String
    let day: Date
    let app: String
    let name: String
    let token: Int64
}

struct CompPoint: Identifiable {
    let id = UUID()
    let date: String
    let day: Date
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let cacheCreate: Int64
    var total: Int64 { input + output + cacheRead + cacheCreate }
}

/// 费用走势点（X 用时间标度）
struct CostPoint: Identifiable {
    let id = UUID()
    let day: Date
    let cents: Int64
}

/// 积分走势点（Trae 口径，X 用时间标度）
struct CreditsPoint: Identifiable {
    let id = UUID()
    let day: Date
    let credits: Double
}

/// 构成堆叠图的展开切片（预先拍平，图表表达式保持轻量）
struct CompSlice: Identifiable {
    let id = UUID()
    let name: String
    let day: Date
    let token: Int64
}

/// 热力图单元格；date 为空 = 首周对齐占位，token = -1
struct HeatCell: Identifiable {
    let id = UUID()
    let date: String
    let token: Int64
}

/// 模型编年史条目：首用/末用时间与累计 token
struct ModelMilestone: Identifiable {
    let id = UUID()
    let model: String
    let firstEpoch: Int64
    let lastEpoch: Int64
    let token: Int64
}

/// app_type 原始值 → 展示名
func appDisplayName(_ raw: String) -> String {
    switch raw {
    case "claude": return "Claude Code"
    case "claude-desktop": return "Claude Desktop"
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "zcode": return "ZCode"
    case "unknown": return L("未知")
    default: return raw
    }
}

@MainActor
final class InsightsViewModel: ObservableObject {
    // 费用
    @Published var costToday = 0.0
    @Published var cost7 = 0.0
    @Published var cost30 = 0.0
    @Published var costDaily: [CostPoint] = []        // 近 30 天，cents = 美分
    @Published var costDaily90: [CostPoint] = []      // 近 90 天（费用页 7/30/90 切换）
    @Published var costModels: [(model: String, cost: Double, token: Int64)] = []
    // 洞察
    @Published var streak = 0
    @Published var thisWeek: Int64 = 0
    @Published var lastWeek: Int64 = 0
    @Published var dailyAvg: Int64 = 0
    @Published var peak: (date: String, token: Int64)?
    @Published var peakHour: Int?
    @Published var topModel: (model: String, token: Int64)?
    @Published var modelHistory: [ModelMilestone] = []
    @Published var appPoints: [AppPoint] = []
    @Published var compDaily: [CompPoint] = []
    @Published var weekdayTotals: [Int64] = Array(repeating: 0, count: 7)   // 周一..周日
    @Published var heatmap: [HeatCell] = []                                  // 91 天 + 首周占位
    @Published var monthProjected: Int64 = 0
    @Published var monthMtd: Int64 = 0
    @Published var totalAll: Int64 = 0
    /// 洞察页范围切换：近 180 天与全量按日 token（升序、含今天）
    @Published var dayTokens: [(date: String, token: Int64)] = []
    @Published var dayTokensAll: [(date: String, token: Int64)] = []
    // 渠道
    @Published var channelPoints: [ChannelPoint] = []
    @Published var todaySources: [SourceStat] = []
    // 流水
    @Published var timeline: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double, account: Int)] = []
    @Published var timelineDay: Date = Calendar.current.startOfDay(for: Date())
    // 积分页（Trae 口径）
    @Published var creditsToday = 0.0
    @Published var credits7 = 0.0
    @Published var credits30 = 0.0
    /// 上期积分（用于统计卡环比）
    @Published var creditsPrevDay = 0.0
    @Published var creditsPrev7 = 0.0
    @Published var creditsPrev30 = 0.0
    @Published var creditsDaily: [CreditsPoint] = []
    /// 积分页 Hero / 余额 / 峰值卡
    @Published var creditsTodayHourly: [Double] = []
    @Published var todayReqs = 0
    @Published var todayCacheHit = 0.0
    @Published var todayActiveMin = 0
    @Published var creditsPeak = 0.0
    @Published var creditsPeakLabel = ""
    @Published var creditsEnt: (consumed: Double, total: Double)?
    @Published var creditsAccounts: [(slot: Int, consumed: Double, total: Double)] = []
    @Published var todayCreditsByAccount: [(slot: Int, credits: Double)] = []
    // 费用页月度预算
    @Published var costMtd = 0.0
    @Published var monthDaysElapsed = 1
    @Published var monthDaysTotal = 30
    @Published var monthlyBudget: Double = 0
    // 未计费渠道按默认单价折算的估算费用
    @Published var estToday = 0.0
    @Published var est7 = 0.0
    @Published var est30 = 0.0
    // 今日会话（30 分钟内连续请求算同一会话）
    @Published var sessionCount = 0
    @Published var sessionAvgMin = 0
    @Published var sessionLongestMin = 0
    // 分享卡近 7 天趋势
    @Published var weekTrend: [ChartEntry] = []
    @Published var shareToday: Int64 = 0
    @Published var shareWeek: Int64 = 0
    @Published var shareMonth: Int64 = 0
    @Published var shareTotal: Int64 = 0
    // 周报（最近一个完整周：上周一 ~ 上周日）
    @Published var weeklyRange: String = ""
    @Published var weeklyTotal: Int64 = 0
    @Published var weeklyReqs: Int = 0
    @Published var weeklyPeak: Int64 = 0
    @Published var weeklyTrend: [ChartEntry] = []

    private var loaded = false
    /// 后台加载代数：窗口快速开关/连续刷新时丢弃过期结果
    private var loadGeneration = 0

    /// 全量加载（一次全查省得各页互相清数据）；查询在后台队列执行，算完回主线程一次性应用。
    /// 曾按页懒加载 + apply 全量覆盖，后加载的页面会把先加载的清零——勿改回。
    func load(force: Bool = false) {
        guard let store = AppDelegate.shared?.store else { return }
        guard force || !loaded else { return }
        loaded = true
        loadGeneration += 1
        let generation = loadGeneration
        let day = timelineDay
        let budget = AppDelegate.shared?.settings.monthlyBudgetUsd ?? 0
        let price = AppDelegate.shared?.settings.defaultTokenPrice ?? 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let snapshot = self.compute(store: store, timelineDay: day,
                                        monthlyBudget: budget, defaultTokenPrice: price)
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.apply(snapshot)
            }
        }
    }

    /// 测试/预览注入 store 的版本（同步执行，便于立即断言）
    func load(store: StatsStore, force: Bool = false) {
        guard force || !loaded else { return }
        loaded = true
        apply(compute(store: store, timelineDay: timelineDay,
                      monthlyBudget: AppDelegate.shared?.settings.monthlyBudgetUsd ?? 0,
                      defaultTokenPrice: AppDelegate.shared?.settings.defaultTokenPrice ?? 0))
    }

    /// 流水页切日期：只重查流水，其余字段不动（一次性全量加载的增量通道）
    func loadTimeline(day: Date) {
        guard let store = AppDelegate.shared?.store else { return }
        let day = Calendar.current.startOfDay(for: day)
        timelineDay = day
        timeline = store.queryTimeline(day: day)
    }

    private struct Snapshot {
        var costToday = 0.0, cost7 = 0.0, cost30 = 0.0
        var costDaily: [CostPoint] = []
        var costDaily90: [CostPoint] = []
        var costModels: [(model: String, cost: Double, token: Int64)] = []
        var streak = 0
        var thisWeek: Int64 = 0, lastWeek: Int64 = 0
        var dailyAvg: Int64 = 0
        var peak: (date: String, token: Int64)?
        var peakHour: Int?
        var topModel: (model: String, token: Int64)?
        var modelHistory: [ModelMilestone] = []
        var appPoints: [AppPoint] = []
        var compDaily: [CompPoint] = []
        var weekdayTotals: [Int64] = Array(repeating: 0, count: 7)
        var heatmap: [HeatCell] = []
        var monthProjected: Int64 = 0
        var monthMtd: Int64 = 0
        var totalAll: Int64 = 0
        var dayTokens: [(date: String, token: Int64)] = []
        var dayTokensAll: [(date: String, token: Int64)] = []
        var channelPoints: [ChannelPoint] = []
        var todaySources: [SourceStat] = []
        var timeline: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double, account: Int)] = []
        var timelineDay: Date = Calendar.current.startOfDay(for: Date())
        var costMtd = 0.0
        var monthDaysElapsed = 1
        var monthDaysTotal = 30
        var monthlyBudget: Double = 0
        var estToday = 0.0
        var est7 = 0.0
        var est30 = 0.0
        var sessionCount = 0
        var sessionAvgMin = 0
        var sessionLongestMin = 0
        var weekTrend: [ChartEntry] = []
        var shareToday: Int64 = 0
        var shareWeek: Int64 = 0
        var shareMonth: Int64 = 0
        var shareTotal: Int64 = 0
        var weeklyRange: String = ""
        var weeklyTotal: Int64 = 0
        var weeklyReqs: Int = 0
        var weeklyPeak: Int64 = 0
        var weeklyTrend: [ChartEntry] = []
        var creditsToday = 0.0
        var credits7 = 0.0
        var credits30 = 0.0
        var creditsPrevDay = 0.0
        var creditsPrev7 = 0.0
        var creditsPrev30 = 0.0
        var creditsDaily: [CreditsPoint] = []
        var creditsTodayHourly: [Double] = []
        var todayReqs = 0
        var todayCacheHit = 0.0
        var todayActiveMin = 0
        var creditsPeak = 0.0
        var creditsPeakLabel = ""
        var creditsEnt: (consumed: Double, total: Double)?
        /// 分账号余额（Trae1/Trae2），仅多账号时有意义
        var creditsAccounts: [(slot: Int, consumed: Double, total: Double)] = []
        /// 今日各账号积分（按槽位，零填充）
        var todayCreditsByAccount: [(slot: Int, credits: Double)] = []
    }

    private nonisolated func compute(store: StatsStore, timelineDay: Date,
                                     monthlyBudget: Double, defaultTokenPrice: Double) -> Snapshot {
        var s = Snapshot()
        s.timelineDay = timelineDay
        // 费用页
        s.costToday = store.queryCost(days: 0)
        s.cost7 = store.queryCost(days: 7)
        s.cost30 = store.queryCost(days: 30)
        let raw = store.queryCostDaily(days: 90)
        // 补齐日期空洞，图表时间轴连续（X 轴用时间标度，轴刻度按需稀疏）
        let fmt = StatsStore.dayFormatter
        let cal = Calendar.current
        var byDate: [String: Double] = [:]
        for r in raw { byDate[r.date] = r.cost }
        var points: [CostPoint] = []
        for d in 0..<90 {
            guard let day = cal.date(byAdding: .day, value: -89 + d, to: cal.startOfDay(for: Date())) else { continue }
            let key = fmt.string(from: day)
            points.append(CostPoint(day: day, cents: Int64((byDate[key] ?? 0) * 100)))
        }
        s.costDaily90 = points
        s.costDaily = Array(points.suffix(30))
        s.costModels = store.queryCostByModel(days: 30, limit: 50)
        let mtd = store.queryCostMTD()
        s.costMtd = mtd.mtd
        s.monthDaysElapsed = mtd.daysElapsed
        s.monthDaysTotal = mtd.daysInMonth
        s.monthlyBudget = monthlyBudget
        // 未计费渠道估算（默认单价 $/M tokens）
        let price = defaultTokenPrice
        if price > 0 {
            s.estToday = Double(store.queryUnmeteredTokens(days: 0)) / 1_000_000 * price
            s.est7 = Double(store.queryUnmeteredTokens(days: 7)) / 1_000_000 * price
            s.est30 = Double(store.queryUnmeteredTokens(days: 30)) / 1_000_000 * price
        }
        // 洞察页
        s.streak = store.queryStreak()
        let delta = store.queryWeeklyDelta()
        s.thisWeek = delta.thisWeek
        s.lastWeek = delta.lastWeek
        let month30Total = store.queryDayStats(days: 30)?.total ?? 0
        s.dailyAvg = month30Total / 30
        s.peak = store.queryPeakDay(days: 30)
        let hist = store.queryHourHistogram(days: 30)
        s.peakHour = hist.max { $0.value < $1.value }?.key
        s.topModel = store.queryTopModel(days: 30)
        s.modelHistory = store.queryModelHistory().map {
            ModelMilestone(model: $0.model, firstEpoch: $0.firstEpoch,
                           lastEpoch: $0.lastEpoch, token: $0.token)
        }
        let totalAll = store.queryTotalStats()?.total ?? 0
        s.totalAll = totalAll
        // 范围切换：180 天按日补齐序列（含今天）+ 全量序列
        func zeroFilled(_ raw: [(date: String, token: Int64)], days: Int) -> [(date: String, token: Int64)] {
            var map: [String: Int64] = [:]
            for r in raw { map[r.date] = r.token }
            var out: [(date: String, token: Int64)] = []
            let todayStart = cal.startOfDay(for: Date())
            for d in 0..<days {
                guard let day = cal.date(byAdding: .day, value: -(days - 1 - d), to: todayStart) else { continue }
                let key = fmt.string(from: day)
                out.append((date: key, token: map[key] ?? 0))
            }
            return out
        }
        s.dayTokens = zeroFilled(store.queryDailyTokens(days: 180), days: 180)
        if let first = store.queryFirstUsageEpoch() {
            let firstDay = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(first)))
            let span = (cal.dateComponents([.day], from: firstDay,
                                           to: cal.startOfDay(for: Date())).day ?? 0) + 1
            let days = min(max(span, 1), 730)
            s.dayTokensAll = zeroFilled(store.queryDailyTokens(days: days), days: days)
        }
        // 构成/应用/星期/热力/月度预测
        s.appPoints = store.queryAppDaily(days: 90).map {
            AppPoint(date: $0.date, day: fmt.date(from: $0.date) ?? Date(),
                     app: $0.app, name: appDisplayName($0.app), token: $0.token)
        }
        s.compDaily = store.queryCompositionDaily(days: 30).map {
            CompPoint(date: $0.date, day: fmt.date(from: $0.date) ?? Date(),
                      input: $0.input, output: $0.output,
                      cacheRead: $0.cacheRead, cacheCreate: $0.cacheCreate)
        }
        let tokens91 = store.queryDailyTokens(days: 91)
        var wd = [Int64](repeating: 0, count: 7)
        for t in tokens91 {
            if let d = fmt.date(from: t.date) {
                wd[(Calendar.current.component(.weekday, from: d) + 5) % 7] += t.token
            }
        }
        s.weekdayTotals = wd
        let start90 = cal.date(byAdding: .day, value: -90, to: cal.startOfDay(for: Date()))!
        let pad = (Calendar.current.component(.weekday, from: start90) + 5) % 7
        var cells: [HeatCell] = []
        for _ in 0..<pad { cells.append(HeatCell(date: "", token: -1)) }
        // 防御：数据异常出现重复日期时不能 trap，取后者
        let tokensByDate = Dictionary(tokens91.map { ($0.date, $0.token) }, uniquingKeysWith: { _, new in new })
        for d in 0..<91 {
            guard let date = cal.date(byAdding: .day, value: d - 90, to: cal.startOfDay(for: Date())) else { continue }
            let key = fmt.string(from: date)
            cells.append(HeatCell(date: key, token: tokensByDate[key] ?? 0))
        }
        s.heatmap = cells
        let mp = store.queryMonthProgress()
        s.monthMtd = mp.mtd
        s.monthProjected = mp.daysElapsed > 0
            ? mp.mtd / Int64(mp.daysElapsed) * Int64(mp.daysInMonth) : 0
        // 分享卡（直接读 store，不依赖 DataCache 的刷新时机）
        s.weekTrend = store.queryDailyTokens(days: 7).map {
            ChartEntry(label: String($0.date.suffix(5)), value: $0.token)
        }
        let todayStats = store.queryDayStats(days: 0)
        s.shareToday = todayStats?.total ?? 0
        s.shareWeek = store.queryDayStats(days: 7)?.total ?? 0
        s.shareMonth = month30Total
        s.shareTotal = totalAll
        // 周报（最近一个完整周：上周一 ~ 上周日）
        let w = WeeklyReport.lastWeekWindow()
        if let ws = store.queryWindowStats(daysAgoFrom: w.from, daysAgoTo: w.to) {
            s.weeklyTotal = ws.total
            s.weeklyReqs = ws.reqs
        }
        let dailyW = store.queryDailyTokensBetween(daysAgoFrom: w.from, daysAgoTo: w.to)
        s.weeklyPeak = dailyW.map(\.token).max() ?? 0
        s.weeklyTrend = dailyW.map { ChartEntry(label: String($0.date.suffix(5)), value: $0.token) }
        let dFmt = DateFormatter(); dFmt.dateStyle = .medium; dFmt.timeStyle = .none
        s.weeklyRange = "\(dFmt.string(from: Date(timeIntervalSince1970: TimeInterval(StatsStore.localMidnight(w.from)))))"
            + " ~ \(dFmt.string(from: Date(timeIntervalSince1970: TimeInterval(StatsStore.localMidnight(w.to)))))"
        // 渠道页（90 天，页面内按 7/30/90 切段）
        s.channelPoints = store.queryChannelDaily(days: 90).map {
            ChannelPoint(date: $0.date, day: fmt.date(from: $0.date) ?? Date(),
                         source: $0.source,
                         name: AppDelegate.shared?.sourceDisplayName($0.source) ?? $0.source,
                         token: $0.token)
        }
        s.todaySources = store.querySourceBreakdown()
        // 流水页（按当前选中日期查，切日期走 loadTimeline 增量刷新）
        s.timeline = store.queryTimeline(day: timelineDay)
        // 今日会话：30 分钟内连续请求算同一会话；须用全量时间戳，流水页只取最近 800 行会少算
        let todayTimes = store.queryTodayRequestTimes()
        let (cnt, avg, longest) = Self.sessionStats(fromTimes: todayTimes)
        s.sessionCount = cnt
        s.sessionAvgMin = avg
        s.sessionLongestMin = longest
        // 积分页（Trae 行 credits 聚合；官方账单余额一并带上）
        s.creditsToday = store.queryCreditsSum(days: 0)
        s.credits7 = store.queryCreditsSum(days: 7)
        s.credits30 = store.queryCreditsSum(days: 30)
        s.creditsPrevDay = store.queryCreditsDay(daysAgo: 1)
        s.creditsPrev7 = store.queryCreditsRange(daysAgoFrom: 13, daysAgoTo: 7)
        s.creditsPrev30 = store.queryCreditsRange(daysAgoFrom: 59, daysAgoTo: 30)
        let rawCredits = store.queryCreditsDaily(days: 30)
        var creditsByDate: [String: Double] = [:]
        for r in rawCredits { creditsByDate[r.date] = r.credits }
        var creditPoints: [CreditsPoint] = []
        for d in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: -29 + d, to: cal.startOfDay(for: Date())) else { continue }
            creditPoints.append(CreditsPoint(day: day, credits: creditsByDate[fmt.string(from: day)] ?? 0))
        }
        s.creditsDaily = creditPoints
        // 积分页 Hero / 余额 / 峰值
        s.creditsTodayHourly = store.queryCreditsHourHistogram(days: 0)
        s.todayReqs = todayStats?.reqs ?? 0
        if let last = s.compDaily.last, last.date == fmt.string(from: Date()) {
            let total = last.input + last.output + last.cacheRead + last.cacheCreate
            s.todayCacheHit = total > 0 ? Double(last.cacheRead) / Double(total) * 100 : 0
        }
        if let mn = todayTimes.first, let mx = todayTimes.last, mx > mn {
            s.todayActiveMin = (mx - mn) / 60
        }
        if let peak = creditPoints.max(by: { $0.credits < $1.credits }) {
            s.creditsPeak = peak.credits
            let mf = DateFormatter()
            mf.locale = Locale(identifier: "zh_CN")
            mf.dateFormat = "M月d日"
            s.creditsPeakLabel = mf.string(from: peak.day)
        }
        s.creditsEnt = store.traeEntSummary()
        s.creditsAccounts = store.traeEntAccounts()
        s.todayCreditsByAccount = store.queryTodayCreditsByAccount()
        return s
    }

    private func apply(_ s: Snapshot) {
        costToday = s.costToday
        cost7 = s.cost7
        cost30 = s.cost30
        costDaily = s.costDaily
        costDaily90 = s.costDaily90
        costModels = s.costModels
        streak = s.streak
        thisWeek = s.thisWeek
        lastWeek = s.lastWeek
        dailyAvg = s.dailyAvg
        peak = s.peak
        peakHour = s.peakHour
        topModel = s.topModel
        modelHistory = s.modelHistory
        appPoints = s.appPoints
        compDaily = s.compDaily
        weekdayTotals = s.weekdayTotals
        heatmap = s.heatmap
        monthProjected = s.monthProjected
        monthMtd = s.monthMtd
        totalAll = s.totalAll
        dayTokens = s.dayTokens
        dayTokensAll = s.dayTokensAll
        channelPoints = s.channelPoints
        todaySources = s.todaySources
        timeline = s.timeline
        timelineDay = s.timelineDay
        costMtd = s.costMtd
        monthDaysElapsed = s.monthDaysElapsed
        monthDaysTotal = s.monthDaysTotal
        monthlyBudget = s.monthlyBudget
        estToday = s.estToday
        est7 = s.est7
        est30 = s.est30
        sessionCount = s.sessionCount
        sessionAvgMin = s.sessionAvgMin
        sessionLongestMin = s.sessionLongestMin
        weekTrend = s.weekTrend
        shareToday = s.shareToday
        shareWeek = s.shareWeek
        shareMonth = s.shareMonth
        shareTotal = s.shareTotal
        weeklyRange = s.weeklyRange
        weeklyTotal = s.weeklyTotal
        weeklyReqs = s.weeklyReqs
        weeklyPeak = s.weeklyPeak
        weeklyTrend = s.weeklyTrend
        creditsToday = s.creditsToday
        credits7 = s.credits7
        credits30 = s.credits30
        creditsPrevDay = s.creditsPrevDay
        creditsPrev7 = s.creditsPrev7
        creditsPrev30 = s.creditsPrev30
        creditsDaily = s.creditsDaily
        creditsTodayHourly = s.creditsTodayHourly
        todayReqs = s.todayReqs
        todayCacheHit = s.todayCacheHit
        todayActiveMin = s.todayActiveMin
        creditsPeak = s.creditsPeak
        creditsPeakLabel = s.creditsPeakLabel
        creditsEnt = s.creditsEnt
        creditsAccounts = s.creditsAccounts
        todayCreditsByAccount = s.todayCreditsByAccount
    }

    /// 今日会话统计：相邻请求间隔 > 30 分钟切新会话，返回（会话数, 平均时长分钟, 最长时长分钟）
    nonisolated static func sessionStats(fromTimes times: [Int]) -> (Int, Int, Int) {
        let times = times.sorted()
        guard !times.isEmpty else { return (0, 0, 0) }
        var durations: [Int] = []
        var start = times[0], last = times[0]
        for t in times.dropFirst() {
            if t - last > 30 * 60 {
                durations.append(last - start)
                start = t
            }
            last = t
        }
        durations.append(last - start)
        let avgMin = durations.reduce(0, +) / max(durations.count, 1) / 60
        let longestMin = (durations.max() ?? 0) / 60
        return (durations.count, avgMin, longestMin)
    }
}

// MARK: - 根视图

struct InsightsRootView: View {
    @ObservedObject var vm: InsightsViewModel
    /// 内嵌设置页复用同一套设置模型；保存后立即应用（不关闭窗口）
    @StateObject private var settingsVM = SettingsViewModel(settings: AppDelegate.shared?.settings ?? Settings()) {
        guard let d = AppDelegate.shared else { return }
        d.connectDB()
        d.startTimer()
        d.updateData()
        d.rebuildStatusBarChrome()
        d.refreshTitleColor()
    }
    // 记住上次停留的页签（重启也保留）
    @AppStorage("insightsLastPage") private var pageRaw: String = InsightsPage.insights.rawValue

    private var pageBinding: Binding<InsightsPage> {
        Binding(
            get: { InsightsPage(rawValue: pageRaw) ?? .insights },
            set: { pageRaw = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color(nsColor: Design.backgroundDark).opacity(0.8))
                detail
                    .padding(18)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { vm.load() }
    }

    /// 左侧图标导航栏（原型风格：顶部 logo + 图标/文字竖排 + 选中左侧指示条）
    private var rail: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(
                        colors: [Color(nsColor: Design.successColor),
                                 Color(nsColor: Design.successColor).opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(nsColor: Design.backgroundDark))
            }
            .frame(width: 28, height: 28)
            .padding(.top, 14)
            .padding(.bottom, 20)

            VStack(spacing: 6) {
                ForEach(InsightsPage.allCases) { railItem($0) }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 78)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: Design.backgroundDark).opacity(0.55))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: Design.separatorColor).opacity(0.6))
                .frame(width: 1)
        }
    }

    private func railItem(_ p: InsightsPage) -> some View {
        let selected = pageBinding.wrappedValue == p
        return Button {
            pageRaw = p.rawValue
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: Design.successColor).opacity(selected ? 0.14 : 0))
                    .frame(width: 54, height: 54)
                VStack(spacing: 6) {
                    Image(systemName: p.icon)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .frame(height: 16)
                    Text(L(p.rawValue))
                        .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                        .fixedSize()
                }
                .foregroundColor(Color(nsColor: selected ? Design.successColor : Design.textMuted))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: Design.successColor))
                    .frame(width: 3, height: 20)
                    .padding(.leading, 3)
                    .opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .help(L(p.rawValue))
    }

    @ViewBuilder
    private var detail: some View {
        switch pageBinding.wrappedValue {
        case .cost: CostPage(vm: vm)
        case .insights: InsightsPageView(vm: vm)
        case .share: SharePage(vm: vm)
        case .channels: ChannelsPage(vm: vm)
        case .timeline: TimelinePage(vm: vm)
        case .credits: CreditsPage(vm: vm)
        case .settings: SettingsRootView(vm: settingsVM)
        }
    }
}

// MARK: - 通用组件

/// NSSavePanel 存 PNG（分享卡 / 洞察长图共用）
func saveImageAsPNG(_ img: NSImage?, _ namePrefix: String) {
    guard let img else { return }
    let panel = NSSavePanel()
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        .replacingOccurrences(of: "/", with: "")
    panel.nameFieldStringValue = "\(namePrefix)-\(stamp).png"
    panel.allowedContentTypes = [.png]
    guard panel.runModal() == .OK, let url = panel.url,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

/// 弹个信息框（模型合并结果等一次性提示）
func showInfoAlert(_ title: String, _ msg: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = msg
    alert.addButton(withTitle: L("好的"))
    alert.runModal()
}

private func pageCard<Content: View>(_ title: String, trailing: String? = nil,
                                    minHeight: CGFloat? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: Design.textPrimary))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .fixedSize()
            }
        }
        content()
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(14)
    .frame(minHeight: minHeight, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
        .fill(Color(nsColor: Design.cardFillDark)))
    .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
        .stroke(Color(nsColor: Design.cardBorderDark)))
}

private func money(_ v: Double) -> String {
    String(format: "$%.2f", v)
}

/// 积分显示：整数不带小数点，小数保留两位（与设置页 fmtCredits 口径一致）
private func formatCredits(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 100_000 ? String(Int(v)) : String(format: "%.2f", v)
}

/// 胶囊分段切换器（范围 / 口径切换）
private struct PillSwitcher<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let active = selection == options[i].0
                Text(options[i].1)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundColor(Color(nsColor: active ? Design.textPrimary : Design.textSecondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(active ? Color.white.opacity(0.1) : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { selection = options[i].0 }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(nsColor: Design.cardFillDark)))
        .overlay(Capsule().stroke(Color(nsColor: Design.cardBorderDark)))
    }
}

// MARK: - 费用页

struct CostPage: View {
    @ObservedObject var vm: InsightsViewModel

    @State private var range: CostRange = .d30

    enum CostRange: String, CaseIterable, Identifiable {
        case d7, d30, d90
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .d7: return 7
            case .d30: return 30
            case .d90: return 90
            }
        }
        var label: String { String(format: L("%d 天"), days) }
    }

    private var series: [CostPoint] { Array(vm.costDaily90.suffix(range.days)) }
    private var seriesTotal: Double { series.reduce(0) { $0 + Double($1.cents) / 100 } }
    private var dailyAvg: Double { seriesTotal / Double(max(series.count, 1)) }
    private var yesterdayCost: Double {
        vm.costDaily90.dropLast().last.map { Double($0.cents) / 100 } ?? 0
    }
    private var peakDay: CostPoint? { series.max { $0.cents < $1.cents } }
    private var monthCost: Double { vm.costMtd > 0 ? vm.costMtd : vm.cost30 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                HStack(alignment: .top, spacing: 14) {
                    todayCard
                    monthCard.frame(width: 290)
                }

                trendCard

                HStack(alignment: .top, spacing: 14) {
                    modelCostCard
                    valueCard
                }

                Text(L("费用按 cc-switch 记录的单价折算；未计费渠道可在设置里配默认单价估算"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("费用"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                Text(L("按官方计费口径 · 美元"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
            Spacer()
            PillSwitcher(options: CostRange.allCases.map { ($0, $0.label) }, selection: $range)
        }
    }

    // MARK: 今日费用（左卡）

    private var todayCard: some View {
        pageCard(L("今日费用"), minHeight: 210) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(money(vm.costToday + vm.estToday))
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.successColor))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    dayDeltaBadge
                    Spacer(minLength: 0)
                }
                costSparkline
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 0) {
                    footerStat(L("近 7 天"), money(vm.cost7 + vm.est7))
                    footerStat(L("近 30 天"), money(vm.cost30 + vm.est30))
                    footerStat(L("日均"), money((vm.cost30 + vm.est30) / 30))
                }
            }
        }
    }

    @ViewBuilder
    private var dayDeltaBadge: some View {
        if yesterdayCost > 0 {
            let d = (vm.costToday - yesterdayCost) / yesterdayCost * 100
            HStack(spacing: 3) {
                Text(L("较昨日"))
                Image(systemName: d >= 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 7, weight: .bold))
                Text(String(format: "%.0f%%", abs(d)))
            }
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundColor(Color(nsColor: Design.warningColor))
            .fixedSize()
        }
    }

    /// 近 30 天费用 sparkline
    private var costSparkline: some View {
        Chart {
            ForEach(vm.costDaily) { p in
                LineMark(x: .value(L("日期"), p.day, unit: .day),
                         y: .value(L("费用"), Double(p.cents) / 100))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color(nsColor: Design.successColor))
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 62)
    }

    private func footerStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.bigNumberColor))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 本月（右卡）

    private var monthCard: some View {
        let budget = vm.monthlyBudget
        let ratio = budget > 0 ? min(monthCost / budget, 1) : 0
        let projected = vm.monthDaysElapsed > 0
            ? monthCost / Double(vm.monthDaysElapsed) * Double(vm.monthDaysTotal) : 0
        return pageCard(L("本月"), minHeight: 210) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(money(monthCost))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.bigNumberColor))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if budget > 0 {
                        Text(L("已用") + " " + String(format: "%.0f%%", ratio * 100))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color(nsColor: Design.textMuted))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                if budget > 0 {
                    progressBar(ratio, color: Design.successColor, height: 6)
                }
                HStack(spacing: 6) {
                    Text(L("预计全月") + " " + money(projected))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textMuted))
                    Spacer(minLength: 0)
                    Text(budget > 0 ? L("额度") + " " + money(budget) : L("未设预算"))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 0) {
                    footerStat(L("单次会话"), money(vm.costToday / Double(max(vm.sessionCount, 1))))
                    footerStat(L("最贵一天"), peakDay.map { money(Double($0.cents) / 100) } ?? "-")
                }
            }
        }
    }

    // MARK: 费用走势（随 7/30/90 切换）

    private var trendCard: some View {
        let month = Calendar.current.component(.month, from: Date())
        return pageCard(String(format: L("近 %d 天费用走势"), range.days),
                        trailing: "\(L("日均")) \(money(dailyAvg))   "
                            + String(format: L("%d 月共"), month) + " " + money(monthCost)) {
            Chart {
                ForEach(series) { p in
                    BarMark(x: .value(L("日期"), p.day, unit: .day),
                            y: .value(L("费用"), Double(p.cents) / 100))
                        .foregroundStyle(LinearGradient(
                            colors: [Color(nsColor: Design.successColor).opacity(0.95),
                                     Color(nsColor: Design.successColor).opacity(0.45)],
                            startPoint: .top, endPoint: .bottom))
                        .cornerRadius(2)
                }
                RuleMark(y: .value(L("日均"), dailyAvg))
                    .foregroundStyle(Color(nsColor: Design.warningColor).opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(L("日均"))
                            .font(.system(size: 9))
                            .foregroundColor(Color(nsColor: Design.warningColor))
                    }
                if vm.monthlyBudget > 0 {
                    budgetRule
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis { dateXAxis() }
            .frame(height: 180)
        }
    }

    // MARK: 模型费用（近 30 天）

    private var modelCostCard: some View {
        let models = vm.costModels
        let shown = Array(models.prefix(5))
        let others = Array(models.dropFirst(5))
        let total = models.reduce(0.0) { $0 + $1.cost }
        let maxCost = max(models.map(\.cost).max() ?? 1, 0.0001)
        return pageCard(L("模型费用"),
                        trailing: L("近 30 天") + " · " + L("合计") + " " + money(total)) {
            if models.isEmpty {
                mutedHint(L("暂无数据"))
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(shown.indices, id: \.self) { i in
                        let m = shown[i]
                        costRow(m.model, money(m.cost),
                                pct: total > 0 ? m.cost / total : 0,
                                ratio: m.cost / maxCost,
                                opacity: [1.0, 0.8, 0.66, 0.55, 0.45][min(i, 4)])
                    }
                    if !others.isEmpty {
                        HStack(spacing: 8) {
                            Text(String(format: L("其他 %d 个模型"), others.count))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                            Spacer()
                            Text(money(others.reduce(0) { $0 + $1.cost }))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                            Text("—")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textMuted))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func costRow(_ name: String, _ cost: String, pct: Double,
                         ratio: Double, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(cost)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.bigNumberColor))
                Text(String(format: "%.0f%%", pct * 100))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .frame(width: 40, alignment: .trailing)
            }
            progressBar(ratio, color: Design.successColor, opacity: opacity)
        }
    }

    // MARK: 性价比榜（近 30 天）

    private var valueCard: some View {
        let ranked = vm.costModels
            .filter { $0.cost > 0.005 }
            .map { (model: $0.model, perDollar: Double($0.token) / $0.cost) }
            .sorted { $0.perDollar > $1.perDollar }
        let top = Array(ranked.prefix(4))
        let maxRate = max(top.map(\.perDollar).max() ?? 1, 1)
        return pageCard(L("性价比榜"), trailing: L("每 $1 换多少 token")) {
            if top.isEmpty {
                mutedHint(L("暂无数据"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(top.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.textSecondary))
                                    .frame(width: 16, height: 16)
                                    .background(RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(i == 0 ? 0.14 : 0.07)))
                                Text(top[i].model)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(nsColor: Design.textPrimary))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(Design.formatTokens(Int64(top[i].perDollar)) + " / $1")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.bigNumberColor))
                            }
                            progressBar(top[i].perDollar / maxRate, color: Design.successColor,
                                        opacity: [1.0, 0.7, 0.55, 0.4][min(i, 3)])
                        }
                    }
                    if let note = valueNote(ranked) {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// 主力模型与第一名的性价比对照（主力本身就是第一时不出文案）
    private func valueNote(_ ranked: [(model: String, perDollar: Double)]) -> String? {
        guard ranked.count >= 2, let topModel = vm.topModel?.model,
              let idx = ranked.firstIndex(where: { $0.model == topModel }), idx > 0 else { return nil }
        let ratio = ranked[0].perDollar / max(ranked[idx].perDollar, 0.0001)
        return String(format: L("%@ 性价比排第 %d，第一名每 $1 多换 %.1f 倍 token，日常任务可优先用它"),
                      ranked[idx].model, idx + 1, ratio)
    }

    /// 进度条（比例 0...1）
    private func progressBar(_ ratio: Double, color: NSColor,
                             opacity: Double = 1, height: CGFloat = 4) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule().fill(Color(nsColor: color).opacity(opacity))
                    .frame(width: max(geo.size.width * CGFloat(min(max(ratio, 0), 1)), 0))
            }
        }
        .frame(height: height)
    }

    // MARK: 月度预算（设置里月度预算 > 0 时出现）

    private var dailyBudget: Double { vm.monthlyBudget / Double(max(vm.monthDaysTotal, 1)) }

    /// 走势图上的日预算虚线
    private var budgetRule: some ChartContent {
        RuleMark(y: .value(L("日预算"), dailyBudget))
            .foregroundStyle(Color(nsColor: Design.warningColor))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .annotation(position: .top, alignment: .trailing) {
                Text(L("日预算 ") + money(dailyBudget))
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: Design.warningColor))
            }
    }
}

// MARK: - 洞察页

struct InsightsPageView: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var range: TrendRange = .d30
    @State private var chronicleExpanded = false
    @State private var showMergeSheet = false
    @State private var mergeFrom = ""
    @State private var mergeTo = ""

    enum TrendRange: String, CaseIterable, Identifiable {
        case d7, d30, d90, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .d7: return L("7 天")
            case .d30: return L("30 天")
            case .d90: return L("90 天")
            case .all: return L("全部")
            }
        }
        var days: Int? {
            switch self {
            case .d7: return 7
            case .d30: return 30
            case .d90: return 90
            case .all: return nil
            }
        }
        var title: String {
            switch self {
            case .d7: return L("近 7 天用量")
            case .d30: return L("近 30 天用量")
            case .d90: return L("近 90 天用量")
            case .all: return L("全部用量")
            }
        }
    }

    private var series: [(date: String, token: Int64)] {
        switch range {
        case .all: return vm.dayTokensAll.isEmpty ? vm.dayTokens : vm.dayTokensAll
        default: return Array(vm.dayTokens.suffix(range.days ?? 30))
        }
    }
    private var rangeTotal: Int64 { series.reduce(0) { $0 + $1.token } }
    private var prevTotal: Int64? {
        guard let d = range.days, vm.dayTokens.count >= d * 2 else { return nil }
        return vm.dayTokens.dropLast(d).suffix(d).reduce(0) { $0 + $1.token }
    }
    private var peakPoint: (date: String, token: Int64)? {
        series.max { $0.token < $1.token }
    }
    /// 主力模型占比分母（历史总量，与原型一致）
    private var shareBase: Int64 {
        vm.totalAll
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                content
            }
        }
        .sheet(isPresented: $showMergeSheet) { mergeSheet }
    }

    /// 页头：标题/数据时刻 + 范围切换 + 导出
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("使用通查"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                Text(L("数据截至") + " " + updatedText + " · " + L("单位 tokens"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
            Spacer()
            Button { exportLongImage() } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .padding(7)
                    .background(Circle().fill(Color(nsColor: Design.cardFillDark)))
                    .overlay(Circle().stroke(Color(nsColor: Design.cardBorderDark)))
            }
            .buttonStyle(.plain)
            .help(L("导出长图"))
            rangeSwitcher
        }
    }

    private var rangeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(TrendRange.allCases) { r in
                Text(r.label)
                    .font(.system(size: 11, weight: range == r ? .semibold : .regular))
                    .foregroundColor(Color(nsColor: range == r ? Design.textPrimary : Design.textSecondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(range == r ? Color.white.opacity(0.1) : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { range = r }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(nsColor: Design.cardFillDark)))
        .overlay(Capsule().stroke(Color(nsColor: Design.cardBorderDark)))
    }

    private var updatedText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date())
    }

    /// 页面内容（长图导出也渲染这份，不含工具行）
    private var content: some View {
        VStack(spacing: 14) {
            heroCard

            HStack(spacing: 14) {
                insightCard(L("连续使用"), "\(vm.streak)", unit: L("天"), icon: "flame.fill",
                            iconColor: Design.warningColor)
                insightCard(L("今日会话"), "\(vm.sessionCount)", unit: L("个"),
                            sub: String(format: L("平均 %d 分钟 · 最长 %d 分钟"),
                                        vm.sessionAvgMin, vm.sessionLongestMin))
                insightCard(L("最活跃时段"), peakHourText, sub: L("近 30 天"))
                insightCard(L("主力模型"), vm.topModel?.model ?? "-",
                            sub: vm.topModel.map {
                                Design.formatTokens($0.token) + " · " + String(format: L("占 %d%%"),
                                    shareBase > 0 ? Int(Double($0.token) / Double(shareBase) * 100) : 0)
                            } ?? "",
                            valueSize: 14)
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 14) {
                weekdayPanel
                heatmapPanel
            }

            chroniclePanel
        }
    }

    /// 统一卡片：标题 + 可选右上说明 + 内容
    private func panel<C: View>(_ title: String, trailing: String? = nil,
                                @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .stroke(Color(nsColor: Design.cardBorderDark)))
    }

    /// Hero：范围总量 + 环比 + 面积走势 + 日均/峰值/历史总量
    private var heroCard: some View {
        panel(range.title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Design.formatTokens(rangeTotal))
                            .font(.system(size: 32, weight: .bold).monospacedDigit())
                            .foregroundColor(Color(nsColor: Design.successColor))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("tokens")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                        rangeDeltaBadge
                    }
                    Spacer()
                    if vm.monthProjected > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L("预计本月消耗"))
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: Design.textMuted))
                            Text(Design.formatTokens(vm.monthProjected))
                                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.bigNumberColor))
                            Text(L("已用") + " " + Design.formatTokens(vm.monthMtd) + " · "
                                 + String(format: "%.0f%%",
                                          vm.monthProjected > 0
                                          ? Double(vm.monthMtd) / Double(vm.monthProjected) * 100 : 0))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textMuted))
                        }
                    }
                }
                rangeChart
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 0) {
                    heroStat(L("日均") + "（\(series.count) " + L("天") + "）",
                             Design.formatTokens(rangeTotal / Int64(max(series.count, 1))))
                    heroStat(L("单日峰值"),
                             peakPoint.map { Design.formatTokens($0.token) } ?? "-",
                             sub: peakPoint?.date ?? "")
                    heroStat(L("历史总量"), Design.formatTokens(vm.totalAll))
                }
            }
        }
    }

    @ViewBuilder
    private var rangeDeltaBadge: some View {
        if let prev = prevTotal, prev > 0 {
            let d = Double(rangeTotal - prev) / Double(prev) * 100
            HStack(spacing: 2) {
                Image(systemName: d >= 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 7, weight: .bold))
                Text(String(format: "%.0f%%", abs(d)))
            }
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundColor(Color(nsColor: d >= 0 ? Design.successColor : Design.warningColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: (d >= 0
                                                      ? Design.successColor : Design.warningColor)).opacity(0.14)))
        }
    }

    /// 面积走势（按索引连续，避免空日断线）
    private var rangeChart: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { i, p in
                AreaMark(x: .value(L("日期"), i),
                         y: .value("Token", p.token))
                    .foregroundStyle(LinearGradient(
                        colors: [Color(nsColor: Design.successColor).opacity(0.28),
                                 Color(nsColor: Design.successColor).opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value(L("日期"), i),
                         y: .value("Token", p.token))
                    .foregroundStyle(Color(nsColor: Design.successColor))
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 96)
    }

    private func heroStat(_ title: String, _ value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.bigNumberColor))
                .lineLimit(1)
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 整页长图（含深色底）存 PNG
    private func exportLongImage() {
        let img = ShareCardRenderer.image(
            content.frame(width: 720)
                .background(Color(nsColor: Design.backgroundDark)),
            width: 720)
        saveImageAsPNG(img, "ccbar-insights")
    }

    // MARK: 星期分布

    private var weekdayPanel: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let labels = (0..<7).map { symbols[($0 + 1) % 7] }
        // 90 天窗口内每个星期几出现次数（约 12~13 次）
        let avg = vm.weekdayTotals.map { Double($0) * 7.0 / 90.0 }
        let maxAvg = max(avg.max() ?? 1, 1)
        let weekdayAvg = (0..<5).reduce(0.0) { $0 + avg[$1] } / 5
        let weekendAvg = (5..<7).reduce(0.0) { $0 + avg[$1] } / 2
        return panel(L("星期分布"), trailing: L("近 90 天均值")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text(String(format: "%.2f", avg[i] / 1e8))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textMuted))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: Design.successColor)
                                    .opacity(i < 5 ? 0.95 : 0.38))
                                .frame(height: CGFloat(avg[i] / maxAvg) * 92 + 4)
                            Text(labels[i])
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: Design.textMuted))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 128, alignment: .bottom)
                HStack(spacing: 14) {
                    Text(L("工作日日均") + " " + String(format: "%.2f", weekdayAvg / 1e8) + " " + L("亿"))
                    Text(L("周末日均") + " " + String(format: "%.2f", weekendAvg / 1e8) + " " + L("亿"))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }

    // MARK: 近 90 天热力

    private var heatmapPanel: some View {
        panel(L("近 90 天热力")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Spacer()
                    Text(L("少"))
                        .font(.system(size: 9))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: Design.successColor)
                                .opacity([0.16, 0.35, 0.6, 0.95][i]))
                            .frame(width: 9, height: 9)
                    }
                    Text(L("多"))
                        .font(.system(size: 9))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
                heatmapGrid
                monthLabels
            }
        }
    }

    /// 底部月份标签（按热力日期去重，等距排布）
    private var monthLabels: some View {
        let months = Self.monthKeys(vm.heatmap)
        return HStack(spacing: 0) {
            ForEach(months, id: \.self) { key in
                Text(Self.monthLabel(key))
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: Design.textMuted))
                if key != months.last { Spacer() }
            }
        }
    }

    static func monthKeys(_ cells: [HeatCell]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in cells where !c.date.isEmpty {
            let key = String(c.date.prefix(7))
            if seen.insert(key).inserted { out.append(key) }
        }
        return out
    }

    static func monthLabel(_ key: String) -> String {
        guard let m = Int(key.suffix(2)) else { return key }
        return L10n.isEnglish ? "\(Calendar.current.shortMonthSymbols[m - 1])" : "\(m)月"
    }

    // MARK: 模型编年史

    private var chroniclePanel: some View {
        let rows = vm.modelHistory.sorted { $0.firstEpoch < $1.firstEpoch }
        let minE = rows.map(\.firstEpoch).min() ?? 0
        let maxE = max(rows.map(\.lastEpoch).max() ?? 0, minE + 1)
        let span = max(Double(maxE - minE), 86400)
        let shown = chronicleExpanded ? rows : Array(rows.prefix(10))
        return panel(L("模型编年史"),
                     trailing: String(format: L("共 %d 个 · 按首次使用排序"), rows.count)) {
            if rows.isEmpty {
                mutedHint(L("暂无数据"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { m in
                        HStack(spacing: 8) {
                            Text(m.model)
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: Design.textPrimary))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                let x = CGFloat(Double(m.firstEpoch - minE) / span) * geo.size.width
                                let w = max(CGFloat(Double(m.lastEpoch - m.firstEpoch) / span) * geo.size.width, 2)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(nsColor: Design.successColor).opacity(0.85))
                                    .frame(width: w, height: 4)
                                    .position(x: x + w / 2, y: geo.size.height / 2)
                            }
                            .frame(height: 8)
                            Text(Design.formatTokens(m.token))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                                .frame(width: 70, alignment: .trailing)
                        }
                        .frame(height: 14)
                    }
                    // 时间轴：月初刻度
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 150, height: 12)
                        GeometryReader { geo in
                            ForEach(Self.monthTicks(from: minE, to: maxE), id: \.epoch) { tick in
                                let x = CGFloat(Double(tick.epoch - minE) / span) * geo.size.width
                                Text(tick.label)
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.textMuted))
                                    .position(x: min(max(x, 16), geo.size.width - 16), y: 6)
                            }
                        }
                        .frame(height: 12)
                        Color.clear.frame(width: 70, height: 12)
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        if rows.count > 10 {
                            Button(chronicleExpanded ? L("收起")
                                   : String(format: L("展开其余 %d 个模型"), rows.count - 10)) {
                                chronicleExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Design.brandColor))
                        }
                        Menu {
                            Button(L("自动合并同名模型")) { autoMerge() }
                            Button(L("手动合并…")) {
                                mergeFrom = vm.modelHistory.first?.model ?? ""
                                mergeTo = mergeFrom
                                showMergeSheet = true
                            }
                        } label: {
                            Label(L("整理模型"), systemImage: "arrow.triangle.merge")
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// 时间轴月初刻度（最多 8 个，避免拥挤）
    static func monthTicks(from: Int64, to: Int64) -> [(epoch: Int64, label: String)] {
        guard to > from else { return [] }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        var start = cal.date(from: cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(from)))) ?? Date()
        if start.timeIntervalSince1970 < Double(from) {
            start = cal.date(byAdding: .month, value: 1, to: start) ?? start
        }
        var out: [(Int64, String)] = []
        var d = start
        while d.timeIntervalSince1970 <= Double(to) && out.count < 8 {
            out.append((Int64(d.timeIntervalSince1970), f.string(from: d)))
            d = cal.date(byAdding: .month, value: 1, to: d) ?? d.addingTimeInterval(86400 * 31)
        }
        return out
    }

    private func autoMerge() {
        guard let store = AppDelegate.shared?.store else { return }
        let (groups, changed) = store.autoMergeModels()
        vm.load(force: true)
        if groups == 0 {
            showInfoAlert(L("没有需要合并的模型"), L("大小写、厂商前缀不同的同名模型都已一致"))
        } else {
            showInfoAlert(L("合并完成"),
                          String(format: L("已合并 %d 组 · 改写 %d 行明细"), groups, changed))
        }
    }

    private func doMerge() {
        guard let store = AppDelegate.shared?.store else { return }
        let changed = store.mergeModel(from: mergeFrom, to: mergeTo)
        showMergeSheet = false
        vm.load(force: true)
        showInfoAlert(L("合并完成"), String(format: L("已改写 %d 行明细"), changed))
    }

    private var mergeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("手动合并模型"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: Design.textPrimary))
            Picker(L("从"), selection: $mergeFrom) {
                ForEach(vm.modelHistory) { m in Text(m.model).tag(m.model) }
            }
            Picker(L("合并到"), selection: $mergeTo) {
                ForEach(vm.modelHistory) { m in Text(m.model).tag(m.model) }
            }
            Text(L("「从」模型的所有明细行会并入「到」模型，操作不可撤销"))
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
            HStack {
                Spacer()
                Button(L("取消")) { showMergeSheet = false }
                Button(L("合并")) { doMerge() }
                    .disabled(mergeFrom == mergeTo || mergeFrom.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    /// 短日期：同年 MM-dd，跨年 yy-MM-dd
    private func shortDate(_ epoch: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epoch))
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
            ? "MM-dd" : "yy-MM-dd"
        return fmt.string(from: d)
    }

    private var weekdayChart: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let labels = (0..<7).map { symbols[($0 + 1) % 7] }
        return Chart {
            ForEach(0..<7, id: \.self) { i in
                BarMark(
                    x: .value(L("星期"), labels[i]),
                    y: .value(L("Token"), vm.weekdayTotals[i])
                )
                .foregroundStyle(Color(nsColor: Design.modelColors(count: 7)[i]).opacity(0.85))
                .cornerRadius(2)
            }
        }
        .chartYAxis { tokenYAxis() }
        .frame(height: 120)
    }

    private var heatmapGrid: some View {
        let weeks = (vm.heatmap.count + 6) / 7
        let maxToken = max(vm.heatmap.map(\.token).max() ?? 1, 1)
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<7, id: \.self) { row in
                GridRow {
                    ForEach(0..<weeks, id: \.self) { col in
                        let idx = col * 7 + row
                        if idx < vm.heatmap.count {
                            let cell = vm.heatmap[idx]
                            RoundedRectangle(cornerRadius: 2)
                                .fill(heatColor(cell.token, maxToken: maxToken))
                                .frame(width: 14, height: 14)
                                .help(cell.date.isEmpty ? "" : "\(cell.date) · \(Design.formatTokens(cell.token))")
                        } else {
                            Color.clear.frame(width: 14, height: 14)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heatColor(_ token: Int64, maxToken: Int64) -> Color {
        guard token >= 0 else { return Color.white.opacity(0.04) }   // 占位
        guard token > 0 else { return Color.white.opacity(0.08) }    // 无用量
        // 绿色色阶（0.18 → 1.0），与原型热力图一致
        let progress = min(Double(token) / Double(maxToken), 1.0)
        return Color(nsColor: Design.successColor)
            .opacity(0.18 + 0.82 * progress)
    }

    private var weekDeltaBadge: String? {
        guard lastWeek > 0 else { return nil }
        let pct = Double(thisWeek - lastWeek) / Double(lastWeek) * 100
        return String(format: "%+.0f%%", pct)
    }

    private var peakHourText: String {
        guard let h = vm.peakHour else { return "-" }
        let next = (h + 1) % 24
        return String(format: "%02d:00 – %02d:00", h, next)
    }

    private var lastWeek: Int64 { vm.lastWeek }
    private var thisWeek: Int64 { vm.thisWeek }

    private func insightCard(_ title: String, _ value: String, unit: String = "",
                             sub: String = "", icon: String? = nil,
                             iconColor: NSColor = Design.textMuted,
                             valueSize: CGFloat = 22) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: iconColor))
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: valueSize, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.bigNumberColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                }
                Spacer(minLength: 0)
            }
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .stroke(Color(nsColor: Design.cardBorderDark)))
    }
}

// MARK: - 分享卡片

struct UsageShareCard: View {
    let title: String               // 右上角标题（战报 / 周报）
    let dateText: String            // 标题下的日期或日期区间
    let bigLabel: String            // 大数字标签
    let bigValue: String            // 大数字（已格式化）
    let trend: [ChartEntry]
    let stats: [(String, String)]   // 底部三格（标题, 值）
    let qrURL = "https://github.com/bmfish/ccbar-native"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CCBar")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(Color(nsColor: Theme.current.accent))
                    Text(dateText)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.55))
                }
                Spacer()
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
            }

            Text(bigLabel)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.75))
            Text(bigValue)
                .font(.system(size: 44, weight: .heavy).monospacedDigit())
                .foregroundColor(Color(nsColor: Theme.current.bigNumberColor))

            if !trend.isEmpty {
                Chart {
                    ForEach(Array(trend.enumerated()), id: \.offset) { _, e in
                        AreaMark(
                            x: .value(L("日期"), e.label),
                            y: .value(L("Token"), e.value)
                        )
                        .foregroundStyle(.linearGradient(
                            colors: [Color(nsColor: Theme.current.accent).opacity(0.55),
                                     Color(nsColor: Theme.current.accent).opacity(0.05)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                        LineMark(
                            x: .value(L("日期"), e.label),
                            y: .value(L("Token"), e.value)
                        )
                        .foregroundStyle(Color(nsColor: Theme.current.accent))
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
            }

            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                    shareStat(s.0, s.1)
                }
            }

            Divider().overlay(Color.white.opacity(0.12))

            HStack(alignment: .bottom) {
                Text("CCBar · github.com/bmfish/ccbar-native")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
                Spacer()
                qrCode
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(nsColor: NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0))))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.10)))
    }

    /// 页脚二维码（指向 GitHub 仓库），白底圆角保证深浅背景都可扫
    @ViewBuilder
    private var qrCode: some View {
        if let qr = QRCodeMaker.image(for: qrURL, pointSize: 46) {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: 46, height: 46)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
        }
    }

    private func shareStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.5))
            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundColor(Color.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SharePage: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var copied = false
    @State private var weeklyCopied = false

    private var card: some View {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return UsageShareCard(
            title: L("AI 用量战报"),
            dateText: fmt.string(from: Date()),
            bigLabel: L("今日消耗"),
            bigValue: Design.formatTokens(vm.shareToday),
            trend: vm.weekTrend,
            stats: [
                (L("近 7 天"), Design.formatTokens(vm.shareWeek)),
                (L("近 30 天"), Design.formatTokens(vm.shareMonth)),
                (L("累计"), Design.formatTokens(vm.shareTotal)),
            ])
    }

    private var weekly: some View {
        weeklyShareCard(dateRange: vm.weeklyRange, total: vm.weeklyTotal,
                        reqs: vm.weeklyReqs, peak: vm.weeklyPeak, trend: vm.weeklyTrend)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Button(L("保存为图片")) { savePNG(ShareCardRenderer.image(card, width: 460), "ccbar-share") }
                        .buttonStyle(.borderedProminent)
                    Button(copied ? L("已复制到剪贴板") : L("复制到剪贴板")) {
                        copyPNG(ShareCardRenderer.image(card, width: 460)) { copied = $0 }
                    }
                    Text(L("晒用量就是最好的宣传 ✨"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }

                Divider().overlay(Color.white.opacity(0.12))

                HStack {
                    Text(L("AI 用量周报（上周）"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(nsColor: Design.textPrimary))
                    Spacer()
                    Button(L("打开周报目录")) { openWeeklyFolder() }
                }
                weekly
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Button(L("保存为图片")) { savePNG(ShareCardRenderer.image(weekly, width: 460), "ccbar-weekly") }
                        .buttonStyle(.borderedProminent)
                    Button(weeklyCopied ? L("已复制到剪贴板") : L("复制到剪贴板")) {
                        copyPNG(ShareCardRenderer.image(weekly, width: 460)) { weeklyCopied = $0 }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func savePNG(_ img: NSImage?, _ namePrefix: String) {
        saveImageAsPNG(img, namePrefix)
    }

    private func copyPNG(_ img: NSImage?, set flag: @escaping (Bool) -> Void) {
        guard let img else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        flag(true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            flag(false)
        }
    }

    /// 打开周报目录（不存在则建），历史周报 PNG 都在这里
    private func openWeeklyFolder() {
        let dir = WeeklyReport.directoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - 二维码（CoreImage CIQRCodeGenerator，无第三方依赖）

enum QRCodeMaker {
    /// 生成二维码图片；pointSize 为最终输出边长（pt）
    static func image(for string: String, pointSize: CGFloat) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = pointSize / output.extent.width
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize))
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - 卡片离屏渲染

enum ShareCardRenderer {
    /// 用 NSHostingView 位图缓存渲染卡片（ImageRenderer 在无窗口环境出黑图，位图缓存两条路都稳）
    static func image<V: View>(_ card: V, width: CGFloat) -> NSImage? {
        let hosting = NSHostingView(rootView: card.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let img = NSImage(size: hosting.bounds.size)
        img.addRepresentation(rep)
        return img
    }

    static func pngData<V: View>(_ card: V, width: CGFloat) -> Data? {
        guard let img = image(card, width: width), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - 周报

/// 周报卡工厂：分享页预览与周一自动落盘共用
func weeklyShareCard(dateRange: String, total: Int64, reqs: Int, peak: Int64, trend: [ChartEntry]) -> UsageShareCard {
    UsageShareCard(
        title: L("AI 用量周报"),
        dateText: dateRange,
        bigLabel: L("周消耗"),
        bigValue: Design.formatTokens(total),
        trend: trend,
        stats: [
            (L("日均"), Design.formatTokens(total / 7)),
            (L("峰值"), Design.formatTokens(peak)),
            (L("请求数"), "\(reqs)"),
        ])
}

/// 周报窗口与目录（洞察页周报卡取数、历史 PNG 目录用；自动生成已移除）
enum WeeklyReport {
    /// 最近一个完整周（上周一 ~ 上周日）的 daysAgo 窗口（均含，不含今日实时）
    static func lastWeekWindow(now: Date = Date()) -> (from: Int, to: Int) {
        let daysSinceMonday = (Calendar.current.component(.weekday, from: now) + 5) % 7
        return (from: daysSinceMonday + 7, to: daysSinceMonday + 1)
    }

    /// 周报输出目录 ~/Documents/CCBar 周报/（测试可注入 directoryOverride）
    static var directoryOverride: URL?
    static func directoryURL() -> URL {
        directoryOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCBar 周报", isDirectory: true)
    }

}

// MARK: - 渠道页

struct ChannelsPage: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var range: ChannelRange = .d30
    @State private var mode: ChannelMode = .channel

    enum ChannelRange: String, CaseIterable, Identifiable {
        case d7, d30, d90
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .d7: return 7
            case .d30: return 30
            case .d90: return 90
            }
        }
        var label: String { String(format: L("%d 天"), days) }
    }

    enum ChannelMode: String, Identifiable {
        case channel, app
        var id: String { rawValue }
        var label: String { self == .channel ? L("按渠道") : L("按应用") }
    }

    /// 构成图展开点
    private struct FlowPoint {
        let day: Date
        let key: String
        let name: String
        let token: Int64
    }

    /// 百分比堆叠切片
    private struct ShareSlice: Identifiable {
        let id = UUID()
        let day: Date
        let name: String
        let share: Double
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                todayCard
                compositionCard
                HStack(alignment: .top, spacing: 14) {
                    tokenMixCard
                    cacheBenefitCard
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("渠道"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                Text(L("渠道 = 接入方式 · 应用 = 实际使用的工具"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
            Spacer()
            PillSwitcher(options: ChannelRange.allCases.map { ($0, $0.label) }, selection: $range)
        }
    }

    // MARK: 今日渠道构成

    private var todayCard: some View {
        let rows = vm.todaySources
        let total = rows.reduce(Int64(0)) { $0 + $1.total }
        let requests = rows.reduce(0) { $0 + $1.reqs }
        let trailing = "\(requests) " + L("次请求") + " · " + Design.formatTokens(total) + " tokens"
        return pageCard(L("今日渠道构成"), trailing: trailing) {
            if rows.isEmpty {
                mutedHint(L("今日暂无请求"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    proportionalBar(rows.indices.map {
                        (Double(rows[$0].total) / Double(max(total, 1)), shade($0))
                    })
                    VStack(spacing: 7) {
                        ForEach(rows.indices, id: \.self) { i in
                            let s = rows[i]
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(shade(i))
                                    .frame(width: 8, height: 8)
                                Text(AppDelegate.shared?.sourceDisplayName(s.source) ?? s.source)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(nsColor: Design.textPrimary))
                                    .lineLimit(1)
                                Text("\(s.reqs) " + L("次"))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.textSecondary))
                                Spacer(minLength: 0)
                                Text(Design.formatTokens(s.total))
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.bigNumberColor))
                                    .frame(width: 84, alignment: .trailing)
                                Text(String(format: "%.0f%%",
                                            total > 0 ? Double(s.total) / Double(total) * 100 : 0))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.textMuted))
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 近 N 天构成变化（按渠道 / 按应用）

    private var compositionCard: some View {
        let totals = flowTotals
        let total = totals.reduce(Int64(0)) { $0 + $1.token }
        let names = totals.map(\.name)
        let colors = totals.indices.map { shade($0) }
        let switchInfo = switchInfo
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(String(format: L("近 %d 天构成变化"), range.days))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                Spacer()
                PillSwitcher(options: [(ChannelMode.channel, L("按渠道")),
                                       (ChannelMode.app, L("按应用"))], selection: $mode)
            }
            if totals.isEmpty {
                mutedHint(L("暂无数据"))
            } else {
                HStack(spacing: 14) {
                    ForEach(totals.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[i]).frame(width: 7, height: 7)
                            Text(totals[i].name)
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: Design.textPrimary))
                            Text(String(format: "%.0f%%",
                                        total > 0 ? Double(totals[i].token) / Double(total) * 100 : 0))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textMuted))
                        }
                    }
                    Spacer(minLength: 0)
                }
                Chart {
                    ForEach(flowSlices) { s in
                        AreaMark(x: .value(L("日期"), s.day, unit: .day),
                                 y: .value(L("占比"), s.share),
                                 series: .value(L("渠道"), s.name))
                            .foregroundStyle(by: .value(L("渠道"), s.name))
                            .interpolationMethod(.monotone)
                    }
                    if let sw = switchInfo {
                        RuleMark(x: .value(L("日期"), sw.day, unit: .day))
                            .foregroundStyle(Color(nsColor: Design.warningColor).opacity(0.75))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text(monthDay(sw.day) + " " + L("切换") + " " + sw.to)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(nsColor: Design.warningColor))
                                    .fixedSize()
                            }
                    }
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartYScale(domain: 0...100)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartXAxis { dateXAxis() }
                .frame(height: 190)
                Text(noteText(switchInfo))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .stroke(Color(nsColor: Design.cardBorderDark)))
    }

    private func noteText(_ sw: (day: Date, to: String, from: String,
                                 fromBefore: Double, fromAfter: Double)?) -> String {
        let base = L("百分比堆叠：纵轴是构成比例，不是用量。")
        guard let sw, !sw.from.isEmpty else { return base }
        return base + " " + String(format: L("%@ 后 %@ 从 %.0f%% 降到 %.0f%%，%@ 接管主要流量。"),
                                   monthDay(sw.day), sw.from, sw.fromBefore, sw.fromAfter, sw.to)
    }

    private func monthDay(_ day: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: day)
        return String(format: L("%d 月 %d 日"), c.month ?? 0, c.day ?? 0)
    }

    /// 占比突增的切换点（当天份额涨幅 > 30 个点才标注）
    private var switchInfo: (day: Date, to: String, from: String,
                             fromBefore: Double, fromAfter: Double)? {
        let totals = flowTotals
        let days = flowDays
        guard totals.count >= 2, days.count >= 2 else { return nil }
        let dayMap = flowDayMap
        var best: (day: Date, to: String, from: String,
                   before: Double, after: Double, gain: Double)?
        for i in 1..<days.count {
            let prevRow = dayMap[days[i - 1]] ?? [:]
            let curRow = dayMap[days[i]] ?? [:]
            let prevTotal = max(prevRow.values.reduce(0, +), 1)
            let curTotal = max(curRow.values.reduce(0, +), 1)
            for t in totals {
                let before = Double(prevRow[t.key] ?? 0) / Double(prevTotal) * 100
                let after = Double(curRow[t.key] ?? 0) / Double(curTotal) * 100
                let gain = after - before
                guard gain > (best?.gain ?? 30) else { continue }
                var loser = ""
                var lBefore = 0.0, lAfter = 0.0, lDrop = 0.0
                for u in totals where u.key != t.key {
                    let b = Double(prevRow[u.key] ?? 0) / Double(prevTotal) * 100
                    let a = Double(curRow[u.key] ?? 0) / Double(curTotal) * 100
                    if b - a > lDrop { lDrop = b - a; loser = u.name; lBefore = b; lAfter = a }
                }
                best = (days[i], t.name, loser, lBefore, lAfter, gain)
            }
        }
        guard let b = best else { return nil }
        return (b.day, b.to, b.from, b.before, b.after)
    }

    // MARK: 构成数据

    private var flowPoints: [FlowPoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(range.days - 1),
                                           to: Calendar.current.startOfDay(for: Date())) ?? Date()
        switch mode {
        case .channel:
            return vm.channelPoints.filter { $0.day >= cutoff }.map {
                FlowPoint(day: Calendar.current.startOfDay(for: $0.day),
                          key: $0.name, name: $0.name, token: $0.token)
            }
        case .app:
            return vm.appPoints.filter { $0.day >= cutoff }.map {
                FlowPoint(day: Calendar.current.startOfDay(for: $0.day),
                          key: $0.name, name: $0.name, token: $0.token)
            }
        }
    }

    private var flowTotals: [(key: String, name: String, token: Int64)] {
        var map: [String: (name: String, token: Int64)] = [:]
        for p in flowPoints {
            let prev = map[p.key]?.token ?? 0
            map[p.key] = (p.name, prev + p.token)
        }
        return map.map { (key: $0.key, name: $0.value.name, token: $0.value.token) }
            .filter { $0.token > 0 }
            .sorted { $0.token > $1.token }
    }

    private var flowDays: [Date] {
        Array(Set(flowPoints.map(\.day))).sorted()
    }

    private var flowDayMap: [Date: [String: Int64]] {
        var map: [Date: [String: Int64]] = [:]
        for p in flowPoints { map[p.day, default: [:]][p.key, default: 0] += p.token }
        return map
    }

    private var flowSlices: [ShareSlice] {
        let totals = flowTotals
        let dayMap = flowDayMap
        var out: [ShareSlice] = []
        for day in flowDays {
            let row = dayMap[day] ?? [:]
            let total = row.values.reduce(0, +)
            guard total > 0 else { continue }
            for t in totals {
                out.append(ShareSlice(day: day, name: t.name,
                                      share: Double(row[t.key] ?? 0) / Double(total) * 100))
            }
        }
        return out
    }

    // MARK: Token 构成（近 30 天）

    private var compSums: (input: Int64, output: Int64, cacheRead: Int64, cacheCreate: Int64) {
        vm.compDaily.reduce((0, 0, 0, 0)) {
            ($0.0 + $1.input, $0.1 + $1.output, $0.2 + $1.cacheRead, $0.3 + $1.cacheCreate)
        }
    }

    private var tokenMixCard: some View {
        let s = compSums
        let total = s.input + s.output + s.cacheRead + s.cacheCreate
        let items: [(name: String, token: Int64, color: Color)] = [
            (L("缓存读"), s.cacheRead, shade(0)),
            (L("输入"), s.input, shade(1)),
            (L("输出"), s.output, shade(2)),
            (L("缓存创建"), s.cacheCreate, shade(3)),
        ]
        return pageCard(L("Token 构成"),
                        trailing: L("近 30 天") + " · " + Design.formatTokens(total),
                        minHeight: 190) {
            if total == 0 {
                mutedHint(L("暂无数据"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    proportionalBar(items.map { (Double($0.token) / Double(total), $0.color) })
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([0, 2], id: \.self) { r in
                            HStack(spacing: 6) {
                                mixLegend(items[r], total: total)
                                mixLegend(items[r + 1], total: total)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 缓存收益（近 30 天构成 + 本月账单）

    private var cacheBenefitCard: some View {
        let s = compSums
        let total = s.input + s.output + s.cacheRead + s.cacheCreate
        let cacheShare = total > 0 ? Double(s.cacheRead) / Double(total) : 0
        let base = vm.costMtd > 0 ? vm.costMtd : vm.cost30
        let saved = base * 0.9 * cacheShare
        let without = base + saved
        let pct = without > 0 ? saved / without : 0
        return pageCard(L("缓存收益"), minHeight: 190) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$" + String(Int(saved.rounded())))
                        .font(.system(size: 28, weight: .bold).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.successColor))
                    Text(L("本月估算省下"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
                Text(String(format: L("%d%% 的 token 命中缓存，按缓存读约为输入价 1/10 计。若全部走输入，本月账单约 %@。"),
                            Int((cacheShare * 100).rounded()), money(without)))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 6) {
                    Text(L("实际") + " " + money(base))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                    Spacer(minLength: 0)
                    Text(L("省") + " " + String(format: "%.0f%%", pct * 100))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.successColor))
                }
                progressBar(pct)
            }
        }
    }

    // MARK: 小组件

    /// 渠道/应用配色：高对比固定色（蓝/橙/绿/紫/红/青），保证相邻序号也能区分
    private func shade(_ i: Int) -> Color {
        let palette = ["#4A90D9", "#E67E22", "#2ECC71", "#9B59B6", "#E74C3C", "#1ABC9C"]
        return Color(nsColor: NSColor(hex: palette[i % palette.count]))
    }

    private func mixLegend(_ item: (name: String, token: Int64, color: Color),
                           total: Int64) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.color)
                .frame(width: 8, height: 8)
            Text(item.name)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textSecondary))
            Spacer(minLength: 0)
            Text(String(format: "%.0f%%", Double(item.token) / Double(max(total, 1)) * 100))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textPrimary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单条构成比例条
    private func proportionalBar(_ segments: [(Double, Color)], height: CGFloat = 8) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(segments[i].1)
                        .frame(width: max(geo.size.width * CGFloat(segments[i].0) - 2, 1))
                }
            }
        }
        .frame(height: height)
    }

    private func progressBar(_ ratio: Double, height: CGFloat = 4) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule().fill(Color(nsColor: Design.successColor))
                    .frame(width: max(geo.size.width * CGFloat(min(max(ratio, 0), 1)), 0))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 积分页（Trae 口径）

struct CreditsPage: View {
    @ObservedObject var vm: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    heroCard
                    balanceCard.frame(width: 300)
                }

                HStack(spacing: 14) {
                    creditsStatCard(L("近 7 天"), vm.credits7, prev: vm.creditsPrev7,
                                    series: Array(vm.creditsDaily.suffix(7)),
                                    color: Design.successColor)
                    creditsStatCard(L("近 30 天"), vm.credits30, prev: vm.creditsPrev30,
                                    series: vm.creditsDaily,
                                    color: Design.successColor)
                    creditsStatCard(L("日均消耗"), dailyAvg,
                                    prev: vm.creditsPrev30 > 0 ? vm.creditsPrev30 / 30 : 0,
                                    series: vm.creditsDaily,
                                    color: Design.warningColor)
                    creditsStatCard(L("峰值单日"), vm.creditsPeak, prev: nil,
                                    series: vm.creditsDaily,
                                    color: Design.textMuted,
                                    sub: vm.creditsPeakLabel)
                }

                trendCard

                Text(L("积分为 Trae 官方计费口径；历史数据自接入起最多回溯 90 天"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }

    private var dailyAvg: Double { vm.credits30 / 30 }
    private var sevenDayRate: Double { vm.credits7 / 7 }
    private var remaining: Double {
        guard let e = vm.creditsEnt else { return 0 }
        return max(e.total - e.consumed, 0)
    }
    /// 按近 7 天日均速率估算余额还能用几天
    private var daysLeft: Int? {
        guard let e = vm.creditsEnt, e.total > 0, sevenDayRate > 0 else { return nil }
        return max(Int((remaining / sevenDayRate).rounded()), 0)
    }
    private var activeDuration: String {
        let m = vm.todayActiveMin
        return m >= 60 ? String(format: "%.1fh", Double(m) / 60) : "\(m)m"
    }

    /// 今日积分 Hero：环比 + 日内走势 + 请求/命中/时长
    private var heroCard: some View {
        cardChrome {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: Design.successColor))
                    Text(L("今日积分"))
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                    Spacer()
                    Button {
                        UserDefaults.standard.set(InsightsPage.timeline.rawValue,
                                                  forKey: "insightsLastPage")
                    } label: {
                        HStack(spacing: 2) {
                            Text(L("明细"))
                            Image(systemName: "chevron.right").font(.system(size: 8))
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                    }
                    .buttonStyle(.plain)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(formatCredits(vm.creditsToday))
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.successColor))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .layoutPriority(1)
                    Text(L("积分"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                        .fixedSize()
                    deltaBadge(delta(vm.creditsToday, vm.creditsPrevDay))
                        .fixedSize()
                }
                // 多账号：今日积分按账号拆分（色点与余额卡一致）
                if vm.todayCreditsByAccount.count > 1 {
                    HStack(spacing: 12) {
                        ForEach(vm.todayCreditsByAccount, id: \.slot) { acc in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(nsColor: acc.slot == 1
                                                ? Design.successColor : .controlAccentColor))
                                    .frame(width: 5, height: 5)
                                Text(formatCredits(acc.credits))
                                    .foregroundColor(Color(nsColor: Design.textSecondary))
                            }
                        }
                        Spacer()
                    }
                    .font(.system(size: 9).monospacedDigit())
                }
                MiniSparkline(values: vm.creditsTodayHourly.map { Int64($0.rounded()) },
                              color: Design.successColor)
                    .frame(height: 52)
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 0) {
                    heroStat(L("请求数"), "\(vm.todayReqs)")
                    heroStat(L("缓存命中"), String(format: "%.0f%%", vm.todayCacheHit))
                    heroStat(L("时长"), activeDuration)
                }
            }
        }
    }

    private func heroStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.bigNumberColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 余额卡：已用大头 + 剩余 + 进度 + 可用天数
    @ViewBuilder
    private var balanceCard: some View {
        cardChrome {
            if let ent = vm.creditsEnt {
                let ratio = ent.total > 0 ? min(max(ent.consumed / ent.total, 0), 1) : 0
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("积分余额"))
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                        Spacer()
                        if let d = daysLeft {
                            Text(L("可用") + " \(d) " + L("天"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: Design.warningColor))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(nsColor: Design.warningColor).opacity(0.14)))
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if ent.total > 0 {
                            Text(formatCredits(remaining))
                                .font(.system(size: 34, weight: .bold).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.successColor))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .layoutPriority(1)
                            Text(L("剩余"))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                                .fixedSize()
                            Spacer()
                            Text(L("已用") + " " + formatCredits(ent.consumed))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textMuted))
                                .fixedSize()
                        } else {
                            Text(formatCredits(ent.consumed))
                                .font(.system(size: 34, weight: .bold).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.bigNumberColor))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(L("已用"))
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                                .fixedSize()
                            Spacer()
                        }
                    }
                    HStack(spacing: 14) {
                        Text(L("近 7 天日均") + " " + formatCredits(sevenDayRate))
                        Text(L("近 30 天日均") + " " + formatCredits(dailyAvg))
                        Spacer()
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .fixedSize()
                    if ent.total > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.06))
                                // 绿色段表示「剩余额度」，越短越接近耗尽
                                Capsule().fill(Color(nsColor: ratio >= 0.85
                                                     ? Design.warningColor : Design.successColor).opacity(0.8))
                                    .frame(width: geo.size.width * CGFloat(max(1 - ratio, 0)))
                            }
                        }
                        .frame(height: 5)
                        HStack {
                            Text("0")
                            Spacer()
                            Text(L("已用") + " " + String(format: "%.0f%%", ratio * 100))
                                .foregroundColor(Color(nsColor: ratio >= 0.85
                                                       ? Design.warningColor : Design.textMuted))
                            Spacer()
                            Text(formatCredits(ent.total))
                        }
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textMuted))
                        // 多账号：分账号余额拆分（色点区分槽位），单账号时顶部大数已表达，不重复
                        if vm.creditsAccounts.count > 1 {
                            VStack(spacing: 3) {
                                ForEach(vm.creditsAccounts, id: \.slot) { acc in
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color(nsColor: acc.slot == 1
                                                        ? Design.successColor : .controlAccentColor))
                                            .frame(width: 5, height: 5)
                                        Spacer()
                                        Text(L("剩余") + " "
                                             + formatCredits(max(acc.total - acc.consumed, 0))
                                             + " / " + formatCredits(acc.total))
                                    }
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.textMuted))
                                }
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    Text(daysLeft.map {
                        L("按近 7 天日均速率，余额约") + " \($0) " + L("天后耗尽")
                    } ?? L("暂无消耗速率，无法估算可用天数"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("积分余额"))
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                    Text(L("未获取到官方账单，同步后展示"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// 近 30 天走势：保留多彩柱，新增均值虚线
    private var trendCard: some View {
        pageCard(L("近 30 天积分走势")) {
            if vm.credits30 <= 0 {
                mutedHint(L("接入 Trae 并产生用量后展示积分消耗"))
            } else {
                HStack(spacing: 12) {
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: Design.successColor)).frame(width: 6, height: 6)
                        Text(L("每日消耗")).font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Design.textMuted))
                    }
                    HStack(spacing: 4) {
                        Capsule().fill(Color(nsColor: Design.warningColor))
                            .frame(width: 12, height: 1.5)
                        Text(L("均值") + " " + formatCredits(dailyAvg))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color(nsColor: Design.textMuted))
                    }
                }
                Chart {
                    ForEach(Array(vm.creditsDaily.enumerated()), id: \.element.id) { i, p in
                        BarMark(
                            x: .value(L("日期"), p.day, unit: .day),
                            y: .value(L("积分"), p.credits)
                        )
                        // 多彩柱色：随小时种子洗牌的调色板逐柱取色（与模型分布卡同一机制）
                        .foregroundStyle(Color(nsColor: Design.modelColors(count: vm.creditsDaily.count)[i]).opacity(0.85))
                        .cornerRadius(2)
                    }
                    RuleMark(y: .value(L("均值"), dailyAvg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color(nsColor: Design.warningColor).opacity(0.75))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatCredits(v)).font(.system(size: 9).monospacedDigit())
                            }
                        }
                    }
                }
                .chartXAxis { dateXAxis() }
                .frame(height: 150)
            }
        }
    }

    /// 卡片统一底色/描边；固定最小高度保证 Hero 与余额卡上下对齐
    private func cardChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
                .fill(Color(nsColor: Design.cardFillDark)))
            .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
                .stroke(Color(nsColor: Design.cardBorderDark)))
    }

    /// 积分统计卡：数值 + 环比 badge（或副标题）+ 迷你走势
    private func creditsStatCard(_ title: String, _ value: Double, prev: Double?,
                                 series: [CreditsPoint], color: NSColor,
                                 sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let sub, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textMuted))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .fixedSize()
                } else {
                    deltaBadge(delta(value, prev))
                        .fixedSize()
                }
            }
            Text(formatCredits(value))
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.bigNumberColor))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            MiniSparkline(values: series.map { Int64($0.credits.rounded()) }, color: color)
                .frame(height: 24)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .stroke(Color(nsColor: Design.cardBorderDark)))
    }

    /// 环比 badge：积分消耗上升用提醒色，下降用正常色
    @ViewBuilder
    private func deltaBadge(_ d: Double?) -> some View {
        if let d {
            let c = d >= 0 ? Design.warningColor : Design.successColor
            Text((d >= 0 ? "▲" : "▼") + String(format: "%.1f%%", abs(d)))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: c))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: c).opacity(0.14)))
        }
    }

    /// 环比百分比；上期为 0 时不显示
    private func delta(_ current: Double, _ prev: Double?) -> Double? {
        guard let prev, prev > 0 else { return nil }
        return (current - prev) / prev * 100
    }
}

// MARK: - 流水页

struct TimelinePage: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var sourceFilter = "all"
    @State private var modelFilter = "all"
    @State private var showCalendar = false
    /// 首屏最多渲染的行数，底部按钮可继续展开
    @State private var visibleCount = 40

    /// 流水页行模型：组头与数据行拍平成单一序列。
    /// 曾用嵌套 ForEach（外层 id=hour、内层 id=offset），30 秒刷新时行视图按位置复用，
    /// 内容会串组错位（20:26 出现在 12:00 组里）——改单层扁平结构后不可能再错。
    enum TimelineLine: Identifiable {
        case header(hour: Int, count: Int, credits: Double)
        case row(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double, account: Int)

        var id: String {
            switch self {
            case .header(let hour, _, _): return "h-\(hour)"
            case .row(let time, _, _, _, _, _, _): return "t-\(time)"
            }
        }
    }

    /// 纯函数：DESC 行序列 → 组头+数据行扁平序列（组头出现在每组最新一行前）
    static func buildLines(_ rows: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double, account: Int)]) -> [TimelineLine] {
        let cal = Calendar.current
        let hours = rows.map { cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval($0.time))) }
        var counts: [Int: Int] = [:]
        var creditSums: [Int: Double] = [:]
        for (i, row) in rows.enumerated() {
            counts[hours[i], default: 0] += 1
            creditSums[hours[i], default: 0] += row.credits
        }
        var out: [TimelineLine] = []
        var last = -1
        for (i, row) in rows.enumerated() {
            let h = hours[i]
            if h != last {
                out.append(.header(hour: h, count: counts[h] ?? 0, credits: creditSums[h] ?? 0))
                last = h
            }
            out.append(.row(time: row.time, model: row.model, source: row.source,
                            token: row.token, cost: row.cost, credits: row.credits,
                            account: row.account))
        }
        return out
    }

    /// 过滤后的流水（渠道/模型），顺序保持 DESC
    private var filtered: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double, account: Int)] {
        vm.timeline.filter { row in
            (sourceFilter == "all" || row.source == sourceFilter) &&
            (modelFilter == "all" || row.model == modelFilter)
        }
    }

    private var sourceOptions: [String] {
        ["all"] + Set(vm.timeline.map(\.source)).sorted()
    }

    private var modelOptions: [String] {
        ["all"] + Set(vm.timeline.map(\.model)).sorted()
    }

    private var lines: [TimelineLine] {
        let all = Self.buildLines(filtered)
        guard filtered.count > visibleCount else { return all }
        // 只渲染前 visibleCount 行，但组头统计仍取整组实数
        var out: [TimelineLine] = []
        var seen = 0
        for line in all {
            if case .row = line {
                if seen >= visibleCount { break }
                seen += 1
            }
            out.append(line)
        }
        return out
    }

    /// 当日合计（不受渠道/模型筛选影响，用于页头）
    private var dayTotals: (credits: Double, tokens: Int64, count: Int) {
        let rows = vm.timeline
        return (rows.reduce(0) { $0 + $1.credits },
                rows.reduce(0) { $0 + $1.token },
                rows.count)
    }

    /// 异常行阈值：单笔 ≥ 当日 10% 积分且不低于 5
    private var anomalyThreshold: Double {
        max(dayTotals.credits * 0.1, 5)
    }

    var body: some View {
        VStack(spacing: 10) {
            pageHeader
            filtersBar
            tableHeader
            detailList
        }
        .padding(.top, 2)
        .onChange(of: vm.timelineDay) { _ in visibleCount = 40 }
        .onChange(of: sourceFilter) { _ in visibleCount = 40 }
        .onChange(of: modelFilter) { _ in visibleCount = 40 }
    }

    /// 页头：标题 + 当日合计 + 较昨日
    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("流水明细"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                Text(headerSummary)
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
            Spacer()
            if isToday, vm.creditsPrevDay > 0, dayTotals.credits > 0 {
                deltaBadge
            }
        }
    }

    private var headerSummary: String {
        let label = L(isToday ? "今日合计" : "当日合计")
        let credits = formatCredits(dayTotals.credits)
        let tokens = Design.formatTokens(dayTotals.tokens)
        return "\(label) \(credits) \(L("积分")) · \(tokens) tokens · \(dayTotals.count) \(L("次请求"))"
    }

    /// 今日积分相对昨日的变化徽标
    private var deltaBadge: some View {
        let d = (dayTotals.credits - vm.creditsPrevDay) / vm.creditsPrevDay * 100
        let color = d >= 0 ? Design.successColor : Design.warningColor
        return HStack(spacing: 3) {
            Text(L("较昨日"))
            Image(systemName: d >= 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text(String(format: "%.0f%%", abs(d)))
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundColor(Color(nsColor: color))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: color).opacity(0.14)))
    }

    /// 表头：时间 / 渠道 / 模型 / 积分 / Tokens
    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text(L("时间")).frame(width: 66, alignment: .leading)
            Text(L("渠道")).frame(width: 52, alignment: .leading)
            Text(L("模型"))
            Spacer()
            Text(L("积分")).frame(width: 70, alignment: .trailing)
            Text("Tokens").frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 10))
        .foregroundColor(Color(nsColor: Design.textMuted))
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { vm.timelineDay },
            set: { vm.loadTimeline(day: $0) }
        )
    }

    // MARK: 日期导航（‹ 前一天 / 后一天 ›，点日期弹日历）

    private var isToday: Bool { Calendar.current.isDateInToday(vm.timelineDay) }

    private var dayLabel: String {
        if isToday { return L("今天") }
        if Calendar.current.isDateInYesterday(vm.timelineDay) { return L("昨天") }
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        return fmt.string(from: vm.timelineDay)
    }

    private func stepDay(_ n: Int) {
        let next = Calendar.current.date(byAdding: .day, value: n, to: vm.timelineDay) ?? vm.timelineDay
        guard next <= Date() else { return }
        vm.loadTimeline(day: next)
    }

    private var dayNav: some View {
        HStack(spacing: 2) {
            Button { stepDay(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(dayLabel) { showCalendar = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(Color(nsColor: isToday ? Design.brandColor : Design.textPrimary))
                .frame(minWidth: 52)
                .popover(isPresented: $showCalendar, arrowEdge: .bottom) {
                    DatePicker("", selection: dayBinding, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(10)
                }
            Button { stepDay(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: isToday ? Design.textMuted : Design.textSecondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isToday)
            if !isToday {
                Button(L("今天")) { vm.loadTimeline(day: Date()) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(nsColor: Design.brandColor))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: Design.brandColor).opacity(0.14)))
                    .padding(.leading, 4)
            }
        }
    }

    private var filtersBar: some View {
        HStack(spacing: 8) {
            dayNav
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(nsColor: Design.cardFillDark)))
                .overlay(Capsule().stroke(Color(nsColor: Design.cardBorderDark)))
            Picker("", selection: $sourceFilter) {
                ForEach(sourceOptions, id: \.self) { option in
                    Text(option == "all" ? L("全部渠道") : (AppDelegate.shared?.sourceDisplayName(option) ?? option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
            Picker("", selection: $modelFilter) {
                ForEach(modelOptions, id: \.self) { option in
                    Text(option == "all" ? L("全部模型") : option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160)
            Spacer()
            Button { exportTimelineCSV() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 10, weight: .semibold))
                    Text(L("导出")).font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color(nsColor: Design.textSecondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(nsColor: Design.cardFillDark)))
                .overlay(Capsule().stroke(Color(nsColor: Design.cardBorderDark)))
            }
            .buttonStyle(.plain)
        }
    }

    /// 当前筛选下的逐笔流水导出 CSV（带 BOM，Excel 直开）
    private func exportTimelineCSV() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var csv = "\u{FEFF}" + [L("时间"), L("模型"), L("渠道"), L("总 Token"), L("费用/积分")]
            .joined(separator: ",") + "\n"
        for line in filtered {
            let t = Date(timeIntervalSince1970: TimeInterval(line.time))
            // 与流水页一致：Trae 行导积分，其他源导美元费用
            let amount = line.source == "trae"
                ? (line.credits > 0 ? formatCredits(line.credits) : "0")
                : (line.cost > 0 ? String(format: "%.4f", line.cost) : "0")
            csv += [fmt.string(from: t), line.model, line.source, "\(line.token)", amount]
                .map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") + "\n"
        }
        let panel = NSSavePanel()
        let stamp = DateFormatter.localizedString(from: vm.timelineDay, dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "")
        panel.nameFieldStringValue = "ccbar-timeline-\(stamp).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private var detailList: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    mutedHint(Calendar.current.isDateInToday(vm.timelineDay)
                              ? L("今日暂无请求") : L("该日暂无请求"))
                    Text(L("去干活吧，流水会记住每一笔 💪"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            switch line {
                            case .header(let hour, let count, let hourCredits):
                                let share = dayTotals.credits > 0 ? hourCredits / dayTotals.credits : 0
                                let featured = share >= 0.25 && hourCredits > 0
                                HStack(spacing: 4) {
                                    Text(String(format: "%02d:00 — %02d:00", hour, (hour + 1) % 24))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Color(nsColor: Design.textMuted))
                                    Spacer()
                                    Text("\(count) " + L("次") + " · " + formatCredits(hourCredits) + " " + L("积分"))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundColor(Color(nsColor: featured ? Design.warningColor
                                                                   : Design.textMuted))
                                    if featured {
                                        Text("· " + L("占今日") + " \(Int((share * 100).rounded()))%")
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundColor(Color(nsColor: Design.warningColor))
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            case .row(let time, let model, let source, let token, let cost, let credits, let account):
                                timelineRow((time, model, source, token, cost, credits, account))
                            }
                        }
                        if filtered.count > visibleCount {
                            Button {
                                visibleCount += 40
                            } label: {
                                Text(L("查看更早") + " \(filtered.count - visibleCount) " + L("条记录"))
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(nsColor: Design.textSecondary))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color(nsColor: Design.cardFillDark)))
                                    .overlay(Capsule().stroke(Color(nsColor: Design.cardBorderDark)))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func timelineRow(_ row: (time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double, account: Int)) -> some View {
        let t = Date(timeIntervalSince1970: TimeInterval(row.time))
        let tfmt = DateFormatter()
        tfmt.dateFormat = "HH:mm:ss"
        // 钱列：Trae 按积分口径显示（cost 是折算金额，积分才是 Trae 的计费单位），其他源仍显示美元费用
        let isTrae = row.source == "trae"
        let isAnomaly = isTrae && row.credits >= anomalyThreshold
        return HStack(spacing: 8) {
            Text(tfmt.string(from: t))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textMuted))
                .frame(width: 66, alignment: .leading)
            sourceChip(row.source)
                .frame(width: 52, alignment: .leading)
            Text(row.model)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: Design.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            // 多账号：色点标记归属账号（与余额卡同色系；历史行 account=0 不标）
            if vm.creditsAccounts.count > 1, row.account > 0 {
                Circle()
                    .fill(Color(nsColor: row.account == 1
                                ? Design.successColor : .controlAccentColor))
                    .frame(width: 5, height: 5)
            }
            if isAnomaly {
                Text(L("异常"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.warningColor))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: Design.warningColor).opacity(0.16)))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if isTrae {
                Text(formatCredits(row.credits))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(Color(nsColor: row.credits > 0 ? Design.successColor : Design.textMuted))
                    .frame(width: 70, alignment: .trailing)
            } else if row.cost > 0 {
                Text(money(row.cost))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .frame(width: 70, alignment: .trailing)
            } else {
                Color.clear.frame(width: 70, height: 1)
            }
            Text(Design.formatTokens(row.token))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textSecondary))
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isAnomaly
                    ? Color(nsColor: Design.warningColor).opacity(0.07)
                    : Color.clear)
        .overlay(alignment: .leading) {
            if isAnomaly {
                Rectangle().fill(Color(nsColor: Design.warningColor)).frame(width: 2)
            }
        }
    }

    /// 渠道小标签（trae 绿色，其他源品牌色）
    private func sourceChip(_ source: String) -> some View {
        let isTrae = source == "trae"
        let c = isTrae ? Design.successColor : Design.brandColor
        let name = isTrae ? "trae" : (AppDelegate.shared?.sourceDisplayName(source) ?? source)
        return Text(name)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color(nsColor: c))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: c).opacity(0.16)))
            .lineLimit(1)
    }
}

// MARK: - 小组件

/// Token 数量轴刻度：按当前语言格式化（亿/万 ↔ K/M）
private func tokenYAxis() -> some AxisContent {
    AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
            if let v = value.as(Int64.self) {
                Text(L10n.formatTokens(v))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }
}

/// 时间轴刻度：自动稀疏（分类轴不理会 desiredCount，时间轴真支持），格式跟随系统语言
private func dateXAxis(count: Int = 5) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: count)) { value in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.month().day(), centered: true)
            .font(.system(size: 9).monospacedDigit())
    }
}

private func mutedHint(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12))
        .foregroundColor(Color(nsColor: Design.textMuted))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 18)
}

// MARK: - 窗口控制器

class InsightsWindowController: NSWindowController {
    let vm = InsightsViewModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("洞察中心")
        window.center()
        window.setFrameAutosaveName("CCBarInsights")
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 680, height: 520)
        window.appearance = NSAppearance(named: .darkAqua)
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: InsightsRootView(vm: vm))
    }

    /// 每次打开全量刷新
    func reload() {
        vm.load(force: true)
    }
}
