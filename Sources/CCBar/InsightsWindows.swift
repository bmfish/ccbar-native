import Cocoa
import SwiftUI
import Charts
import CoreImage

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

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cost: return "dollarsign.circle"
        case .insights: return "sparkles"
        case .share: return "square.and.arrow.up"
        case .channels: return "square.stack.3d.up"
        case .timeline: return "list.bullet.rectangle"
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
    @Published var timeline: [(time: Int, model: String, source: String, token: Int64, cost: Double)] = []
    // 分享卡近 7 天趋势
    @Published var weekTrend: [ChartEntry] = []
    @Published var shareToday: Int64 = 0
    @Published var shareWeek: Int64 = 0
    @Published var shareMonth: Int64 = 0
    @Published var shareTotal: Int64 = 0

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
        var timeline: [(time: Int, model: String, source: String, token: Int64, cost: Double)] = []
        var weekTrend: [ChartEntry] = []
        var shareToday: Int64 = 0
        var shareWeek: Int64 = 0
        var shareMonth: Int64 = 0
        var shareTotal: Int64 = 0
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
        // 渠道页
        s.channelPoints = store.queryChannelDaily(days: 30).map {
            ChannelPoint(date: $0.date, day: fmt.date(from: $0.date) ?? Date(),
                         source: $0.source,
                         name: AppDelegate.shared?.sourceDisplayName($0.source) ?? $0.source,
                         token: $0.token)
        }
        s.todaySources = store.querySourceBreakdown()
        // 流水页
        s.timeline = store.queryTodayTimeline()
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
        weekTrend = s.weekTrend
        shareToday = s.shareToday
        shareWeek = s.shareWeek
        shareMonth = s.shareMonth
        shareTotal = s.shareTotal
    }
}

// MARK: - 根视图

struct InsightsRootView: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var page: InsightsPage = .cost

    var body: some View {
        NavigationSplitView {
            List(InsightsPage.allCases, selection: $page) { p in
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
        switch page {
        case .cost: CostPage(vm: vm)
        case .insights: InsightsPageView(vm: vm)
        case .share: SharePage(vm: vm)
        case .channels: ChannelsPage(vm: vm)
        case .timeline: TimelinePage(vm: vm)
        }
    }
}

// MARK: - 通用组件

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

// MARK: - 费用页

struct CostPage: View {
    @ObservedObject var vm: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    bigCostCard(L("今日费用"), vm.costToday)
                    bigCostCard(L("近 7 天"), vm.cost7)
                    bigCostCard(L("近 30 天"), vm.cost30)
                }

                pageCard(L("近 30 天费用走势")) {
                    Chart {
                        ForEach(vm.costDaily) { p in
                            BarMark(
                                x: .value(L("日期"), p.day, unit: .day),
                                y: .value(L("费用"), Double(p.cents) / 100)
                            )
                            .foregroundStyle(Color(nsColor: Design.brandColor).opacity(0.85))
                            .cornerRadius(2)
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

                Text(L("费用按 cc-switch 记录的单价折算；ZCode 渠道官方未计费，不计入"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
    }

    private func bigCostCard(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: Design.textSecondary))
            Text(money(value))
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

// MARK: - 洞察页

struct InsightsPageView: View {
    @ObservedObject var vm: InsightsViewModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                insightCard("🔥 " + L("连续使用"), "\(vm.streak)", unit: L("天"))
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

    @ViewBuilder
    private var modelChronicle: some View {
        if vm.modelHistory.isEmpty {
            mutedHint(L("暂无数据"))
        } else {
            VStack(spacing: 8) {
                ForEach(vm.modelHistory) { m in
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
            }
        }
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
                .foregroundStyle(Color(nsColor: Design.brandColor).opacity(0.85))
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                card
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Button(L("保存为图片")) { savePNG() }
                        .buttonStyle(.borderedProminent)
                    Button(copied ? L("已复制到剪贴板") : L("复制到剪贴板")) { copyPNG() }
                    Text(L("晒用量就是最好的宣传 ✨"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func renderPNG() -> NSImage? {
        ShareCardRenderer.image(card, width: 460)
    }

    private func savePNG() {
        guard let img = renderPNG() else { return }
        let panel = NSSavePanel()
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "")
        panel.nameFieldStringValue = "ccbar-share-\(stamp).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private func copyPNG() {
        guard let img = renderPNG() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
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

// MARK: - 周报自动生成

/// 每周一自动生成上周（周一 ~ 周日）用量周报 PNG，存到 ~/Documents/CCBar 周报/。
/// 幂等键 = 报告周的周一日期（lastWeeklyReportWeek），同周重复触发不重复生成。
enum WeeklyReport {
    /// 上周窗口（daysAgo 均含，7 = 上周一 … 1 = 上周日，不含今日实时）
    static let windowFrom = 7, windowTo = 1

    @MainActor
    @discardableResult
    static func generateIfNeeded(store: StatsStore, now: Date = Date()) -> String? {
        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == 2 else { return nil }   // 只在周一生成
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let weekKey = fmt.string(from: now)
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "lastWeeklyReportWeek") != weekKey else { return nil }

        guard let stats = store.queryWindowStats(daysAgoFrom: windowFrom, daysAgoTo: windowTo),
              stats.total > 0 else {
            defaults.set(weekKey, forKey: "lastWeeklyReportWeek")   // 没数据也记账，避免反复查
            return nil
        }
        let daily = store.queryDailyTokensBetween(daysAgoFrom: windowFrom, daysAgoTo: windowTo)
        let peakToken = daily.map(\.token).max() ?? 0

        let dateFmt = DateFormatter(); dateFmt.dateStyle = .medium; dateFmt.timeStyle = .none
        let from = cal.date(byAdding: .day, value: -windowFrom, to: cal.startOfDay(for: now))!
        let to = cal.date(byAdding: .day, value: -windowTo, to: cal.startOfDay(for: now))!

        let card = UsageShareCard(
            title: L("AI 用量周报"),
            dateText: "\(dateFmt.string(from: from)) ~ \(dateFmt.string(from: to))",
            bigLabel: L("周消耗"),
            bigValue: Design.formatTokens(stats.total),
            trend: daily.map { ChartEntry(label: String($0.date.suffix(5)), value: $0.token) },
            stats: [
                (L("日均"), Design.formatTokens(stats.total / 7)),
                (L("峰值"), Design.formatTokens(peakToken)),
                (L("累计"), Design.formatTokens(stats.total)),
            ])

        guard let png = ShareCardRenderer.pngData(card, width: 460) else {
            NSLog("[weekly] 周报渲染失败")
            return nil
        }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCBar 周报", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ccbar-weekly-\(weekKey).png")
        do {
            try png.write(to: url)
            defaults.set(weekKey, forKey: "lastWeeklyReportWeek")
            NSLog("[weekly] 周报已生成 \(url.path)")
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

// MARK: - 流水页

struct TimelinePage: View {
    @ObservedObject var vm: InsightsViewModel
    @State private var sourceFilter = "all"
    @State private var modelFilter = "all"

    /// 流水页行模型：组头与数据行拍平成单一序列。
    /// 曾用嵌套 ForEach（外层 id=hour、内层 id=offset），30 秒刷新时行视图按位置复用，
    /// 内容会串组错位（20:26 出现在 12:00 组里）——改单层扁平结构后不可能再错。
    enum TimelineLine: Identifiable {
        case header(hour: Int, count: Int)
        case row(time: Int, model: String, source: String, token: Int64, cost: Double)

        var id: String {
            switch self {
            case .header(let hour, _): return "h-\(hour)"
            case .row(let time, _, _, _, _): return "t-\(time)"
            }
        }
    }

    /// 纯函数：DESC 行序列 → 组头+数据行扁平序列（组头出现在每组最新一行前）
    static func buildLines(_ rows: [(time: Int, model: String, source: String, token: Int64, cost: Double)]) -> [TimelineLine] {
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
                            token: row.token, cost: row.cost))
        }
        return out
    }

    /// 过滤后的流水（渠道/模型），顺序保持 DESC
    private var filtered: [(time: Int, model: String, source: String, token: Int64, cost: Double)] {
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

    private var filtersBar: some View {
        HStack(spacing: 10) {
            Text(L("筛选"))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textMuted))
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
        }
    }

    private var detailList: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    mutedHint(L("今日暂无请求"))
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
                            case .row(let time, let model, let source, let token, let cost):
                                timelineRow((time, model, source, token, cost))
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func timelineRow(_ row: (time: Int, model: String, source: String, token: Int64, cost: Double)) -> some View {
        let t = Date(timeIntervalSince1970: TimeInterval(row.time))
        let timeText = DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .medium)
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
            if row.cost > 0 {
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
