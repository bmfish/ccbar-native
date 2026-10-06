import Cocoa
import SwiftUI
import Charts

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
    let source: String
    let name: String
    let token: Int64
}

struct AppPoint: Identifiable {
    let id = UUID()
    let date: String
    let app: String
    let name: String
    let token: Int64
}

struct CompPoint: Identifiable {
    let id = UUID()
    let date: String
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let cacheCreate: Int64
    var total: Int64 { input + output + cacheRead + cacheCreate }
}

/// 构成堆叠图的展开切片（预先拍平，图表表达式保持轻量）
struct CompSlice: Identifiable {
    let id = UUID()
    let name: String
    let date: String
    let token: Int64
}

/// 热力图单元格；date 为空 = 首周对齐占位，token = -1
struct HeatCell: Identifiable {
    let id = UUID()
    let date: String
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
    @Published var costDaily: [ChartEntry] = []       // 近 30 天，value = 美分（避免动 ChartEntry 的 Int64）
    @Published var costModels: [(model: String, cost: Double, token: Int64)] = []
    // 洞察
    @Published var streak = 0
    @Published var thisWeek: Int64 = 0
    @Published var lastWeek: Int64 = 0
    @Published var dailyAvg: Int64 = 0
    @Published var peak: (date: String, token: Int64)?
    @Published var peakHour: Int?
    @Published var topModel: (model: String, token: Int64)?
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
        var costDaily: [ChartEntry] = []
        var costModels: [(model: String, cost: Double, token: Int64)] = []
        var streak = 0
        var thisWeek: Int64 = 0, lastWeek: Int64 = 0
        var dailyAvg: Int64 = 0
        var peak: (date: String, token: Int64)?
        var peakHour: Int?
        var topModel: (model: String, token: Int64)?
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
        // 补齐日期空洞，图表时间轴连续
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        var byDate: [String: Double] = [:]
        for r in raw { byDate[r.date] = r.cost }
        var entries: [ChartEntry] = []
        for d in 0..<30 {
            guard let date = cal.date(byAdding: .day, value: -29 + d, to: cal.startOfDay(for: Date())) else { continue }
            let key = fmt.string(from: date)
            entries.append(ChartEntry(label: String(key.suffix(5)),
                                      value: Int64((byDate[key] ?? 0) * 100)))
        }
        s.costDaily = entries
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
        s.totalAll = store.queryTotalStats()?.total ?? 0
        // 构成/应用/星期/热力/月度预测
        s.appPoints = store.queryAppDaily(days: 30).map {
            AppPoint(date: $0.date, app: $0.app, name: appDisplayName($0.app), token: $0.token)
        }
        s.compDaily = store.queryCompositionDaily(days: 30).map {
            CompPoint(date: $0.date, input: $0.input, output: $0.output,
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
            ChannelPoint(date: $0.date, source: $0.source,
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
                        ForEach(vm.costDaily, id: \.label) { e in
                            BarMark(
                                x: .value(L("日期"), e.label),
                                y: .value(L("费用"), Double(e.value) / 100)
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
                    .chartXAxis { sparseXAxis() }
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
        }
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
        let base = Color(nsColor: Theme.current.accent)
        switch Double(token) / Double(maxToken) {
        case ..<0.25: return base.opacity(0.30)
        case ..<0.5: return base.opacity(0.50)
        case ..<0.75: return base.opacity(0.72)
        default: return base.opacity(0.95)
        }
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
    let today: Int64
    let week: Int64
    let month: Int64
    let total: Int64
    let trend: [ChartEntry]
    let dateText: String

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
                Text(L("AI 用量战报"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
            }

            Text(L("今日消耗"))
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.75))
            Text(Design.formatTokens(today))
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
                shareStat(L("近 7 天"), Design.formatTokens(week))
                shareStat(L("近 30 天"), Design.formatTokens(month))
                shareStat(L("累计"), Design.formatTokens(total))
            }

            Divider().overlay(Color.white.opacity(0.12))

            Text("CCBar · github.com/bmfish/ccbar-native")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.white.opacity(0.4))
        }
        .padding(22)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(nsColor: NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0))))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.10)))
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
            today: vm.shareToday,
            week: vm.shareWeek,
            month: vm.shareMonth,
            total: vm.shareTotal,
            trend: vm.weekTrend,
            dateText: fmt.string(from: Date()))
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
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.nsImage
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
                        x: .value(L("日期"), p.date),
                        y: .value(L("Token"), p.token),
                        series: .value(L("渠道"), p.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(L("渠道"), p.name))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { tokenYAxis() }
            .chartXAxis { sparseXAxis() }
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
                        x: .value(L("日期"), p.date),
                        y: .value(L("Token"), p.token),
                        series: .value(L("应用"), p.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(L("应用"), p.name))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { tokenYAxis() }
            .chartXAxis { sparseXAxis() }
            .frame(height: 160)
        }
    }

    private var compCard: some View {
        pageCard(L("近 30 天 Token 构成")) {
            Chart {
                ForEach(compSlices) { slice in
                    AreaMark(
                        x: .value(L("日期"), slice.date),
                        y: .value(L("Token"), slice.token),
                        series: .value(L("构成"), slice.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value(L("构成"), slice.name))
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { tokenYAxis() }
            .chartXAxis { sparseXAxis() }
            .frame(height: 160)
        }
    }

    private var compSlices: [CompSlice] {
        let names = [L("输入"), L("输出"), L("缓存读"), L("缓存创建")]
        let keys: [KeyPath<CompPoint, Int64>] = [\.input, \.output, \.cacheRead, \.cacheCreate]
        var out: [CompSlice] = []
        for (i, name) in names.enumerated() {
            for p in vm.compDaily {
                out.append(CompSlice(name: name, date: p.date, token: p[keyPath: keys[i]]))
            }
        }
        return out
    }

    private var hitRateCard: some View {
        pageCard(L("缓存命中率（近 30 天）")) {
            Chart {
                ForEach(vm.compDaily) { p in
                    LineMark(
                        x: .value(L("日期"), p.date),
                        y: .value(L("命中率"), hitRate(p))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color(nsColor: Design.brandColor))
                }
            }
            .chartYScale(domain: 0...100)
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

    /// 按小时分组（数据已是最新在前）
    private var grouped: [(hour: Int, rows: [(time: Int, model: String, source: String, token: Int64, cost: Double)])] {
        var out: [(hour: Int, rows: [(time: Int, model: String, source: String, token: Int64, cost: Double)])] = []
        var buckets: [Int: (Int, [(time: Int, model: String, source: String, token: Int64, cost: Double)])] = [:]
        for row in vm.timeline {
            let h = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(row.time)))
            if buckets[h] == nil {
                buckets[h] = (out.count, [])
                out.append((h, []))
            }
            out[buckets[h]!.0].rows.append(row)
        }
        return out
    }

    var body: some View {
        Group {
            if vm.timeline.isEmpty {
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
                        ForEach(grouped, id: \.hour) { group in
                            HStack {
                                Text(String(format: "%02d:00 – %02d:00", group.hour, (group.hour + 1) % 24))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(nsColor: Design.textMuted))
                                Spacer()
                                Text("\(group.rows.count) " + L("次"))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Color(nsColor: Design.textMuted))
                            }
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.001))   // 让整行可点区域稳定
                            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                                timelineRow(row)
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

/// 分类轴只留 5 个刻度，避免日期标签挤成省略号
private func sparseXAxis() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisValueLabel {
            if let s = value.as(String.self) {
                Text(s).font(.system(size: 9).monospacedDigit())
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
        }
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
