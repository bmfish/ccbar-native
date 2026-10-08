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
    case cost       = "费用"
    case insights   = "洞察"
    case share      = "分享"
    case channels   = "渠道"
    case timeline   = "流水"
    case credits    = "积分"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cost: return "dollarsign.circle"
        case .insights: return "sparkles"
        case .share: return "square.and.arrow.up"
        case .channels: return "square.stack.3d.up"
        case .timeline: return "list.bullet.rectangle"
        case .credits: return "bolt.circle"
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
    // 渠道
    @Published var channelPoints: [ChannelPoint] = []
    @Published var todaySources: [SourceStat] = []
    // 流水
    @Published var timeline: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)] = []
    @Published var timelineDay: Date = Calendar.current.startOfDay(for: Date())
    // 积分页（Trae 口径）
    @Published var creditsToday = 0.0
    @Published var credits7 = 0.0
    @Published var credits30 = 0.0
    @Published var creditsDaily: [CreditsPoint] = []
    @Published var creditsEnt: (consumed: Double, total: Double)?
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

    /// 全量加载（查询都是索引区间扫描，实测 < 20ms，一次全查省得各页互相清数据）。
    /// 曾按页懒加载 + apply 全量覆盖，后加载的页面会把先加载的清零——勿改回。
    func load(force: Bool = false) {
        guard let store = AppDelegate.shared?.store else { return }
        load(store: store, force: force)
    }

    /// 测试/预览注入 store 的版本
    func load(store: StatsStore, force: Bool = false) {
        guard force || !loaded else { return }
        loaded = true
        apply(compute(store: store))
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
        var channelPoints: [ChannelPoint] = []
        var todaySources: [SourceStat] = []
        var timeline: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)] = []
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
        var creditsDaily: [CreditsPoint] = []
        var creditsEnt: (consumed: Double, total: Double)?
    }

    private func compute(store: StatsStore) -> Snapshot {
        var s = Snapshot()
        // 费用页
        s.costToday = store.queryCost(days: 0)
        s.cost7 = store.queryCost(days: 7)
        s.cost30 = store.queryCost(days: 30)
        let raw = store.queryCostDaily(days: 30)
        // 补齐日期空洞，图表时间轴连续（X 轴用时间标度，轴刻度按需稀疏）
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        var byDate: [String: Double] = [:]
        for r in raw { byDate[r.date] = r.cost }
        var points: [CostPoint] = []
        for d in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: -29 + d, to: cal.startOfDay(for: Date())) else { continue }
            let key = fmt.string(from: day)
            points.append(CostPoint(day: day, cents: Int64((byDate[key] ?? 0) * 100)))
        }
        s.costDaily = points
        s.costModels = store.queryCostByModel(days: 30)
        let mtd = store.queryCostMTD()
        s.costMtd = mtd.mtd
        s.monthDaysElapsed = mtd.daysElapsed
        s.monthDaysTotal = mtd.daysInMonth
        s.monthlyBudget = AppDelegate.shared?.settings.monthlyBudgetUsd ?? 0
        // 未计费渠道估算（默认单价 $/M tokens）
        let price = AppDelegate.shared?.settings.defaultTokenPrice ?? 0
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
        s.dailyAvg = (store.queryDayStats(days: 30)?.total ?? 0) / 30
        s.peak = store.queryPeakDay(days: 30)
        let hist = store.queryHourHistogram(days: 30)
        s.peakHour = hist.max { $0.value < $1.value }?.key
        s.topModel = store.queryTopModel(days: 30)
        s.modelHistory = store.queryModelHistory().map {
            ModelMilestone(model: $0.model, firstEpoch: $0.firstEpoch,
                           lastEpoch: $0.lastEpoch, token: $0.token)
        }
        s.totalAll = store.queryTotalStats()?.total ?? 0
        // 构成/应用/星期/热力/月度预测
        s.appPoints = store.queryAppDaily(days: 30).map {
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
        let tokensByDate = Dictionary(uniqueKeysWithValues: tokens91.map { ($0.date, $0.token) })
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
        s.shareToday = store.queryDayStats(days: 0)?.total ?? 0
        s.shareWeek = store.queryDayStats(days: 7)?.total ?? 0
        s.shareMonth = store.queryDayStats(days: 30)?.total ?? 0
        s.shareTotal = store.queryTotalStats()?.total ?? 0
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
        // 渠道页
        s.channelPoints = store.queryChannelDaily(days: 30).map {
            ChannelPoint(date: $0.date, day: fmt.date(from: $0.date) ?? Date(),
                         source: $0.source,
                         name: AppDelegate.shared?.sourceDisplayName($0.source) ?? $0.source,
                         token: $0.token)
        }
        s.todaySources = store.querySourceBreakdown()
        // 流水页（按当前选中日期查，切日期走 loadTimeline 增量刷新）
        s.timeline = store.queryTimeline(day: timelineDay)
        // 今日会话：30 分钟内连续请求算同一会话
        let (cnt, avg, longest) = Self.sessionStats(from: s.timeline)
        s.sessionCount = cnt
        s.sessionAvgMin = avg
        s.sessionLongestMin = longest
        // 积分页（Trae 行 credits 聚合；官方账单余额一并带上）
        s.creditsToday = store.queryCreditsSum(days: 0)
        s.credits7 = store.queryCreditsSum(days: 7)
        s.credits30 = store.queryCreditsSum(days: 30)
        let rawCredits = store.queryCreditsDaily(days: 30)
        var creditsByDate: [String: Double] = [:]
        for r in rawCredits { creditsByDate[r.date] = r.credits }
        var creditPoints: [CreditsPoint] = []
        for d in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: -29 + d, to: cal.startOfDay(for: Date())) else { continue }
            creditPoints.append(CreditsPoint(day: day, credits: creditsByDate[fmt.string(from: day)] ?? 0))
        }
        s.creditsDaily = creditPoints
        s.creditsEnt = store.traeEntSummary()
        return s
    }

    private func apply(_ s: Snapshot) {
        costToday = s.costToday
        cost7 = s.cost7
        cost30 = s.cost30
        costDaily = s.costDaily
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
        creditsDaily = s.creditsDaily
        creditsEnt = s.creditsEnt
    }

    /// 今日会话统计：相邻请求间隔 > 30 分钟切新会话，返回（会话数, 平均时长分钟, 最长时长分钟）
    static func sessionStats(from rows: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)]) -> (Int, Int, Int) {
        let times = rows.map(\.time).sorted()
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
    // 记住上次停留的页签（重启也保留）
    @AppStorage("insightsLastPage") private var pageRaw: String = InsightsPage.cost.rawValue

    private var pageBinding: Binding<InsightsPage> {
        Binding(
            get: { InsightsPage(rawValue: pageRaw) ?? .cost },
            set: { pageRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(InsightsPage.allCases, selection: pageBinding) { p in
                Label(L(p.rawValue), systemImage: p.icon)
                    .tag(p)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150)
        } detail: {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color(nsColor: Design.backgroundDark).opacity(0.8))
                detail
                    .padding(18)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { vm.load() }
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

private func pageCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(nsColor: Design.textPrimary))
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
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

// MARK: - 费用页

struct CostPage: View {
    @ObservedObject var vm: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    bigCostCard(L("今日费用"), vm.costToday, estimated: vm.estToday)
                    bigCostCard(L("近 7 天"), vm.cost7, estimated: vm.est7)
                    bigCostCard(L("近 30 天"), vm.cost30, estimated: vm.est30)
                }

                if vm.monthlyBudget > 0 {
                    budgetCard
                }

                pageCard(L("近 30 天费用走势")) {
                    Chart {
                        ForEach(Array(vm.costDaily.enumerated()), id: \.element.id) { i, p in
                            BarMark(
                                x: .value(L("日期"), p.day, unit: .day),
                                y: .value(L("费用"), Double(p.cents) / 100)
                            )
                            // 多彩柱色：随小时种子洗牌的调色板逐柱取色（与积分页同一机制）
                            .foregroundStyle(Color(nsColor: Design.modelColors(count: vm.costDaily.count)[i]).opacity(0.85))
                            .cornerRadius(2)
                        }
                        if vm.monthlyBudget > 0 {
                            budgetRule
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(money(v)).font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .chartXAxis { dateXAxis() }
                    .frame(height: 140)
                }

                pageCard(L("模型费用排行（近 30 天）")) {
                    if vm.costModels.isEmpty {
                        mutedHint(L("暂无数据"))
                    } else {
                        let maxCost = vm.costModels.map(\.cost).max() ?? 1
                        VStack(spacing: 8) {
                            ForEach(vm.costModels.indices, id: \.self) { i in
                                let m = vm.costModels[i]
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(nsColor: Design.modelColors(count: max(vm.costModels.count, 1))[i]))
                                        .frame(width: 8, height: 8)
                                    Text(m.model)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(nsColor: Design.textPrimary))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(money(m.cost))
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundColor(Color(nsColor: Design.dataHighlightColor))
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.06))
                                        Capsule().fill(Color(nsColor: Design.brandColor).opacity(0.75))
                                            .frame(width: geo.size.width * CGFloat(max(m.cost, 0) / max(maxCost, 0.0001)))
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                }

                pageCard(L("性价比榜（近 30 天）")) {
                    let ranked = vm.costModels
                        .filter { $0.cost > 0.005 }
                        .map { (model: $0.model, perDollar: Double($0.token) / $0.cost) }
                        .sorted { $0.perDollar > $1.perDollar }
                    if ranked.isEmpty {
                        mutedHint(L("暂无数据"))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(ranked.indices, id: \.self) { i in
                                HStack(spacing: 8) {
                                    Text("\(i + 1). \(ranked[i].model)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(nsColor: Design.textPrimary))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(Design.formatTokens(Int64(ranked[i].perDollar)) + " / $1")
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundColor(Color(nsColor: Design.dataHighlightColor))
                                }
                            }
                        }
                    }
                }

                Text(L("费用按 cc-switch 记录的单价折算；未计费渠道可在设置里配默认单价估算"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }

    private func bigCostCard(_ title: String, _ value: Double, estimated: Double = 0) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: Design.textSecondary))
            Text(money(value + estimated))
                .font(.system(size: 26, weight: .bold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.bigNumberColor))
            if estimated > 0 {
                Text(L("实测 ") + money(value) + L(" · 估算 ") + money(estimated))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .stroke(Color(nsColor: Design.cardBorderDark)))
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

    private var budgetCard: some View {
        let ratio = vm.costMtd / vm.monthlyBudget
        let over = vm.costMtd > vm.monthlyBudget
        let projected = Double(vm.monthDaysElapsed) > 0
            ? vm.costMtd / Double(vm.monthDaysElapsed) * Double(vm.monthDaysTotal) : 0
        return pageCard(String(format: L("本月预算 $%.2f"), vm.monthlyBudget)) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.06))
                        Capsule().fill(Color(nsColor: Design.usageColor(progress: CGFloat(min(ratio, 1)))))
                            .frame(width: geo.size.width * CGFloat(min(ratio, 1)))
                    }
                }
                .frame(height: 6)
                HStack(alignment: .firstTextBaseline) {
                    Text(L("本月已花 ") + money(vm.costMtd))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textPrimary))
                    Spacer()
                    Text(over
                         ? L("已超预算 ") + money(vm.costMtd - vm.monthlyBudget)
                         : L("剩余 ") + money(vm.monthlyBudget - vm.costMtd))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(nsColor: over ? Design.errorColor : Design.successColor))
                }
                Text(L("按当前速率预计 ") + money(projected)
                     + L(" · 已用预算 ") + String(format: "%.0f%%", ratio * 100))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }
}

// MARK: - 洞察页

struct InsightsPageView: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var chronicleExpanded = false
    @State private var showMergeSheet = false
    @State private var mergeFrom = ""
    @State private var mergeTo = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    Button(L("导出长图")) { exportLongImage() }
                        .font(.system(size: 11))
                }
                content
            }
        }
        .sheet(isPresented: $showMergeSheet) { mergeSheet }
    }

    /// 页面内容（长图导出也渲染这份，不含工具行）
    private var content: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                insightCard("🔥 " + L("连续使用"), "\(vm.streak)", unit: L("天"))
                insightCard(L("今日会话"), "\(vm.sessionCount)", unit: L("个"),
                            sub: String(format: L("平均 %d 分钟 · 最长 %d 分钟"),
                                        vm.sessionAvgMin, vm.sessionLongestMin))
                insightCard(L("本周用量"), Design.formatTokens(vm.thisWeek),
                            badge: weekDeltaBadge)
                insightCard(L("日均用量（近 30 天）"), Design.formatTokens(vm.dailyAvg))
                insightCard(L("历史总量"), Design.formatTokens(vm.totalAll))
                insightCard(L("单日峰值（近 30 天）"),
                            vm.peak.map { Design.formatTokens($0.token) } ?? "-",
                            sub: vm.peak?.date ?? "")
                insightCard(L("最活跃时段（近 30 天）"), peakHourText)
                insightCard(L("使用量最大的模型（近 30 天）"),
                            vm.topModel.map { Design.formatTokens($0.token) } ?? "-",
                            sub: vm.topModel?.model ?? "")
                insightCard(L("预计本月消耗"), Design.formatTokens(vm.monthProjected),
                            sub: String(format: L("按当前速率 · 本月已用 %@"), Design.formatTokens(vm.monthMtd)))
            }
            .frame(maxWidth: .infinity)

            pageCard(L("星期分布（近 90 天）")) {
                weekdayChart
            }

            pageCard(L("近 90 天用量热力图")) {
                heatmapGrid
            }

            pageCard(L("模型编年史")) {
                modelChronicle
            }
        }
    }

    /// 整页长图（含深色底）存 PNG
    private func exportLongImage() {
        let img = ShareCardRenderer.image(
            content.frame(width: 720)
                .background(Color(nsColor: Design.backgroundDark)),
            width: 720)
        saveImageAsPNG(img, "ccbar-insights")
    }

    @ViewBuilder
    private var modelChronicle: some View {
        if vm.modelHistory.isEmpty {
            mutedHint(L("暂无数据"))
        } else {
            VStack(spacing: 8) {
                // 默认只列前 10 个（按首用时间），点了再展开全部
                let shown = chronicleExpanded ? vm.modelHistory : Array(vm.modelHistory.prefix(10))
                ForEach(shown) { m in
                    HStack(spacing: 8) {
                        Text(m.model)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(nsColor: Design.textPrimary))
                            .lineLimit(1)
                        Text("\(shortDate(m.firstEpoch)) → \(shortDate(m.lastEpoch))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color(nsColor: Design.textMuted))
                        Spacer()
                        Text(Design.formatTokens(m.token))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundColor(Color(nsColor: Design.dataHighlightColor))
                            .frame(width: 84, alignment: .trailing)
                    }
                }
                if vm.modelHistory.count > 10 {
                    Button(chronicleExpanded ? L("收起") :
                            String(format: L("展开全部 %d 个模型"), vm.modelHistory.count)) {
                        chronicleExpanded.toggle()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(Color(nsColor: Design.brandColor))
                }
                HStack {
                    Spacer()
                    Menu {
                        Button(L("自动合并同名模型")) { autoMerge() }
                        Button(L("手动合并…")) {
                            mergeFrom = vm.modelHistory.first?.model ?? ""
                            mergeTo = mergeFrom
                            showMergeSheet = true
                        }
                    } label: {
                        Label(L("整理模型"), systemImage: "arrow.triangle.merge")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                    }
                    .fixedSize()
                }
            }
        }
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
        // 用量色阶（绿→黄→橙→红），与菜单栏阈值变色同一套视觉语言
        let progress = min(Double(token) / Double(maxToken), 1.0)
        return Color(nsColor: Design.usageColor(progress: progress))
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

    private func insightCard(_ title: String, _ value: String, unit: String = "", badge: String? = nil, sub: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: Design.textSecondary))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.bigNumberColor))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(nsColor: badge.hasPrefix("-") ? Design.successColor : Design.warningColor))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                Spacer()
            }
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
        // 撑满网格单元：同排卡片顶/底对齐（有无副行都一样高）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
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
                    Text(L("每周一自动生成到周报目录 🗓"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: Design.textMuted))
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

/// 周报自动生成

/// 每周一自动生成上周（周一 ~ 周日）用量周报 PNG，存到 ~/Documents/CCBar 周报/。
/// 幂等键 = 报告周的周一日期（lastWeeklyReportWeek），同周重复触发不重复生成。
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

    /// 报告标识 = 上一个完整周后面的那个周一（也是文件名日期），一周内任何一天补生成同一个文件
    static func reportKey(now: Date = Date()) -> String {
        let w = lastWeekWindow(now: now)
        return StatsStore.dayString(fromEpoch: StatsStore.localMidnight(w.to - 1, now: now))
    }

    /// 生成"上一个完整周"的周报。周一例行出报；其余日子用来补账——周一没开机也不会错过。
    /// 幂等：周报文件已存在即跳过，删掉文件可在下次启动重新生成。
    @MainActor
    @discardableResult
    static func generateIfNeeded(store: StatsStore, now: Date = Date()) -> String? {
        if let app = AppDelegate.shared, !app.settings.autoWeeklyReport { return nil }

        let w = lastWeekWindow(now: now)
        let dir = directoryURL()
        let url = dir.appendingPathComponent("ccbar-weekly-\(reportKey(now: now)).png")
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let stats = store.queryWindowStats(daysAgoFrom: w.from, daysAgoTo: w.to),
              stats.total > 0 else { return nil }   // 该周无数据；查询很便宜，不记账下次再试
        let daily = store.queryDailyTokensBetween(daysAgoFrom: w.from, daysAgoTo: w.to)
        let peakToken = daily.map(\.token).max() ?? 0

        let dateFmt = DateFormatter(); dateFmt.dateStyle = .medium; dateFmt.timeStyle = .none
        let from = Calendar.current.date(byAdding: .day, value: -w.from, to: Calendar.current.startOfDay(for: now))!
        let to = Calendar.current.date(byAdding: .day, value: -w.to, to: Calendar.current.startOfDay(for: now))!

        let card = weeklyShareCard(
            dateRange: "\(dateFmt.string(from: from)) ~ \(dateFmt.string(from: to))",
            total: stats.total, reqs: stats.reqs, peak: peakToken,
            trend: daily.map { ChartEntry(label: String($0.date.suffix(5)), value: $0.token) })

        guard let png = ShareCardRenderer.pngData(card, width: 460) else {
            NSLog("[weekly] 周报渲染失败")
            return nil
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            NSLog("[weekly] 周报已生成 \(url.path)")
            AppDelegate.shared?.sendNotification(
                title: L("上周周报已生成"),
                body: L("已存到 CCBar 周报目录，点击打开洞察中心查看"),
                identifier: "ccbar.weekly",
                category: "CCBAR_WEEKLY")
            return url.path
        } catch {
            NSLog("[weekly] 周报写入失败 \(error)")
            return nil
        }
    }
}

// MARK: - 渠道页

struct ChannelsPage: View {
    @ObservedObject var vm: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                channelChartCard
                todayChannelsCard
                appDistCard
                compCard
                hitRateCard
            }
        }
    }

    private var channelChartCard: some View {
        pageCard(L("近 30 天渠道用量（堆叠）")) {
            Chart {
                ForEach(vm.channelPoints) { p in
                    AreaMark(
                        x: .value(L("日期"), p.day, unit: .day),
                        y: .value(L("Token"), p.token),
                        series: .value(L("渠道"), p.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(L("渠道"), p.name))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { tokenYAxis() }
            .chartXAxis { dateXAxis() }
            .frame(height: 200)
        }
    }

    private var todayChannelsCard: some View {
        pageCard(L("今日各渠道")) {
            if vm.todaySources.isEmpty {
                mutedHint(L("暂无数据"))
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.todaySources, id: \.source) { s in
                        HStack {
                            Text("● \(AppDelegate.shared?.sourceDisplayName(s.source) ?? s.source)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(nsColor: Design.brandColor))
                            Spacer()
                            Text("\(s.reqs) " + L("次"))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                            Text(Design.formatTokens(s.total))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.dataHighlightColor))
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var appDistCard: some View {
        pageCard(L("近 30 天应用分布（堆叠）")) {
            Chart {
                ForEach(vm.appPoints) { p in
                    AreaMark(
                        x: .value(L("日期"), p.day, unit: .day),
                        y: .value(L("Token"), p.token),
                        series: .value(L("应用"), p.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(L("应用"), p.name))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { tokenYAxis() }
            .chartXAxis { dateXAxis() }
            .frame(height: 160)
        }
    }

    private var compCard: some View {
        pageCard(L("近 30 天 Token 构成")) {
            Chart {
                ForEach(compSlices) { slice in
                    AreaMark(
                        x: .value(L("日期"), slice.day, unit: .day),
                        y: .value(L("Token"), slice.token),
                        series: .value(L("构成"), slice.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(L("构成"), slice.name))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { tokenYAxis() }
            .chartXAxis { dateXAxis() }
            .frame(height: 160)
        }
    }

    private var compSlices: [CompSlice] {
        let names = [L("输入"), L("输出"), L("缓存读"), L("缓存创建")]
        let keys: [KeyPath<CompPoint, Int64>] = [\.input, \.output, \.cacheRead, \.cacheCreate]
        var out: [CompSlice] = []
        for (i, name) in names.enumerated() {
            for p in vm.compDaily {
                out.append(CompSlice(name: name, day: p.day, token: p[keyPath: keys[i]]))
            }
        }
        return out
    }

    private var hitRateCard: some View {
        pageCard(L("缓存命中率（近 30 天）")) {
            Chart {
                ForEach(vm.compDaily) { p in
                    LineMark(
                        x: .value(L("日期"), p.day, unit: .day),
                        y: .value(L("命中率"), hitRate(p))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color(nsColor: Design.brandColor))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { dateXAxis() }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.0f%%", v)).font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 120)
        }
    }

    private func hitRate(_ p: CompPoint) -> Double {
        Double(p.cacheRead) / Double(max(p.total, 1)) * 100
    }
}

// MARK: - 积分页（Trae 口径）

struct CreditsPage: View {
    @ObservedObject var vm: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    bigCreditsCard(L("今日积分"), vm.creditsToday)
                    bigCreditsCard(L("近 7 天"), vm.credits7)
                    bigCreditsCard(L("近 30 天"), vm.credits30)
                }

                if let ent = vm.creditsEnt {
                    pageCard(L("积分余额（官方账单）")) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatCredits(ent.consumed))
                                .font(.system(size: 22, weight: .bold).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.dataHighlightColor))
                            Text(L("已用 / 共") + " " + formatCredits(ent.total))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundColor(Color(nsColor: Design.textSecondary))
                            Spacer()
                            if ent.total > 0 {
                                Text(String(format: "%.0f%%", ent.consumed / ent.total * 100))
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.brandColor))
                            }
                        }
                        if ent.total > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.06))
                                    Capsule().fill(Color(nsColor: Design.brandColor).opacity(0.75))
                                        .frame(width: geo.size.width * CGFloat(min(max(ent.consumed / ent.total, 0), 1)))
                                }
                            }
                            .frame(height: 5)
                            .padding(.top, 6)
                        }
                    }
                }

                pageCard(L("近 30 天积分走势")) {
                    if vm.credits30 <= 0 {
                        mutedHint(L("接入 Trae 并产生用量后展示积分消耗"))
                    } else {
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
                        .frame(height: 140)
                    }
                }

                Text(L("积分为 Trae 官方计费口径；历史数据自接入起最多回溯 90 天"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }

    private func bigCreditsCard(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: Design.textSecondary))
            Text(formatCredits(value))
                .font(.system(size: 26, weight: .bold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.bigNumberColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .stroke(Color(nsColor: Design.cardBorderDark)))
    }
}

// MARK: - 流水页

struct TimelinePage: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var sourceFilter = "all"
    @State private var modelFilter = "all"
    @State private var showCalendar = false

    /// 流水页行模型：组头与数据行拍平成单一序列。
    /// 曾用嵌套 ForEach（外层 id=hour、内层 id=offset），30 秒刷新时行视图按位置复用，
    /// 内容会串组错位（20:26 出现在 12:00 组里）——改单层扁平结构后不可能再错。
    enum TimelineLine: Identifiable {
        case header(hour: Int, count: Int)
        case row(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)

        var id: String {
            switch self {
            case .header(let hour, _): return "h-\(hour)"
            case .row(let time, _, _, _, _, _): return "t-\(time)"
            }
        }
    }

    /// 纯函数：DESC 行序列 → 组头+数据行扁平序列（组头出现在每组最新一行前）
    static func buildLines(_ rows: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)]) -> [TimelineLine] {
        let cal = Calendar.current
        let hours = rows.map { cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval($0.time))) }
        var counts: [Int: Int] = [:]
        for h in hours { counts[h, default: 0] += 1 }
        var out: [TimelineLine] = []
        var last = -1
        for (i, row) in rows.enumerated() {
            let h = hours[i]
            if h != last {
                out.append(.header(hour: h, count: counts[h] ?? 0))
                last = h
            }
            out.append(.row(time: row.time, model: row.model, source: row.source,
                            token: row.token, cost: row.cost, credits: row.credits))
        }
        return out
    }

    /// 过滤后的流水（渠道/模型），顺序保持 DESC
    private var filtered: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)] {
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
        Self.buildLines(filtered)
    }

    var body: some View {
        VStack(spacing: 8) {
            filtersBar
            detailList
        }
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
        HStack(spacing: 10) {
            Text(L("筛选"))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textMuted))
            dayNav
            Picker("", selection: $sourceFilter) {
                ForEach(sourceOptions, id: \.self) { option in
                    Text(option == "all" ? L("全部渠道") : (AppDelegate.shared?.sourceDisplayName(option) ?? option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Picker("", selection: $modelFilter) {
                ForEach(modelOptions, id: \.self) { option in
                    Text(option == "all" ? L("全部模型") : option).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            Spacer()
            Button(L("导出 CSV")) { exportTimelineCSV() }
                .font(.system(size: 11))
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
                            case .header(let hour, let count):
                                HStack {
                                    Text(String(format: "%02d:00 – %02d:00", hour, (hour + 1) % 24))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(nsColor: Design.textMuted))
                                    Spacer()
                                    Text("\(count) " + L("次"))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundColor(Color(nsColor: Design.textMuted))
                                }
                                .padding(.vertical, 8)
                            case .row(let time, let model, let source, let token, let cost, let credits):
                                timelineRow((time, model, source, token, cost, credits))
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func timelineRow(_ row: (time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)) -> some View {
        let t = Date(timeIntervalSince1970: TimeInterval(row.time))
        let timeText = DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .medium)
        // 钱列：Trae 按积分口径显示（cost 是折算金额，积分才是 Trae 的计费单位），其他源仍显示美元费用
        let isTrae = row.source == "trae"
        return HStack(spacing: 10) {
            Text(timeText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textMuted))
                .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: Design.brandColor))
                .frame(width: 3, height: 14)
            Text(AppDelegate.shared?.sourceDisplayName(row.source) ?? row.source)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: Design.brandColor))
                .frame(width: 76, alignment: .leading)
                .lineLimit(1)
            Text(row.model)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isTrae {
                if row.credits > 0 {
                    Text("\(formatCredits(row.credits)) " + L("积分"))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                }
            } else if row.cost > 0 {
                Text(money(row.cost))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textSecondary))
            }
            Text(Design.formatTokens(row.token))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.dataHighlightColor))
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 4)
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
        window.minSize = NSSize(width: 680, height: 460)
        window.appearance = NSAppearance(named: .darkAqua)
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: InsightsRootView(vm: vm))
    }

    /// 每次打开全量刷新
    func reload() {
        vm.load(force: true)
    }
}
