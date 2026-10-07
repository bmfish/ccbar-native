import Cocoa
import SwiftUI
import Charts

// MARK: - 弹窗动作桥（连接旧的 AppDelegate selector 流程）

struct PopoverActions {
    let openHourlyToday: () -> Void
    let openHourlyYesterday: () -> Void
    let openWeek: () -> Void
    let openMonth: () -> Void
    let openModelToday: () -> Void
    let copy: () -> Void
    let refresh: () -> Void
    let insights: () -> Void
    let settings: () -> Void
    let quit: () -> Void

    static let shared = PopoverActions(
        openHourlyToday: { AppDelegate.shared?.openHourlyDetailToday() },
        openHourlyYesterday: { AppDelegate.shared?.openHourlyDetailYesterday() },
        openWeek: { AppDelegate.shared?.openDetail() },
        openMonth: { AppDelegate.shared?.openMonthDetail() },
        openModelToday: { AppDelegate.shared?.openModelDetailToday() },
        copy: { AppDelegate.shared?.copyStats() },
        refresh: { AppDelegate.shared?.refreshData() },
        insights: { AppDelegate.shared?.openInsights() },
        settings: { AppDelegate.shared?.openSettingsAndClose() },
        quit: { AppDelegate.shared?.quit() }
    )
}

/// 今日逐小时用量点（弹窗折线图）
struct HourPoint: Identifiable {
    let id = UUID()
    let hourDate: Date
    let token: Int64
}

// MARK: - ViewModel（主线程读缓存，驱动 SwiftUI 重渲染）

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var today: DayStats?
    @Published var yesterday: DayStats?
    @Published var week: DayStats?
    @Published var month: DayStats?
    @Published var total: TotalStats?
    @Published var models: [ModelStat] = []
    @Published var workHours: Double?
    @Published var theme: Theme = .current
    @Published var todayHourly: [HourPoint] = []

    /// 问候语：初始化时随机一次，之后每次打开弹窗重新抽（rollGreeting）
    @Published var greeting: String

    init(greeting: String? = nil) {
        self.greeting = greeting ?? AppDelegate.shared?.greetings.randomElement() ?? "ccBar 用量统计"
    }

    /// 弹窗每次打开时重新随机问候语（popover 实例常驻，不重抽会一直显示同一句）
    func rollGreeting() {
        greeting = AppDelegate.shared?.greetings.randomElement() ?? greeting
    }

    func refresh() {
        let c = DataCache.shared
        today = c.getCachedToday()
        yesterday = c.getCachedYesterday()
        week = c.getCachedWeek()
        month = c.getCachedMonth()
        total = c.getCachedTotal()
        models = c.getCachedModelBreakdown() ?? []
        workHours = c.getCachedWorkHours()
        theme = .current
        if let store = AppDelegate.shared?.store {
            todayHourly = Self.hourPoints(from: store.queryHourHistogram(days: 0))
        }
    }

    /// 逐时序列：起点 = 今天首个有数据的整点，但首数据晚于 9 点时固定从 9 点起线
    ///（9 点是稳定的工作日锚点）；结尾 = 最后一个有数据的小时——
    /// 刚开始的当前小时还没有数据，不画它，避免线尾坠到零
    static func hourPoints(from hist: [Int: Int64]) -> [HourPoint] {
        let cal = Calendar.current
        let now = Date()
        let dataHours = hist.filter { $0.value > 0 }.map(\.key)
        guard let first = dataHours.min() else { return [] }
        let start = min(first, 9)
        let last = dataHours.max() ?? first
        guard start <= last else { return [] }
        let startOfDay = cal.startOfDay(for: now)
        var out: [HourPoint] = []
        for h in start...last {
            let date = cal.date(byAdding: .hour, value: h, to: startOfDay) ?? now
            out.append(HourPoint(hourDate: date, token: hist[h] ?? 0))
        }
        return out
    }

    /// 按已跑时长把今日用量折算到 24:00
    var predictionText: String? {
        guard let t = today, let h = workHours, h > 0.2 else { return nil }
        let predicted = Double(t.total) / (h * 3600) * 86_400
        return String(format: L("按当前速率到 24:00 约 %@"), Design.formatTokens(Int64(predicted)))
    }
}

// MARK: - 宿主控制器（保持类名，AppDelegate 无感切换）

final class PopoverViewController: NSHostingController<PopoverRootView> {
    private let vm: PopoverViewModel

    init() {
        let vm = PopoverViewModel()
        self.vm = vm
        super.init(rootView: PopoverRootView(vm: vm))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        vm.refresh()
    }

    /// 每次打开弹窗时重新随机问候语
    func rollGreeting() {
        vm.rollGreeting()
    }
}

// MARK: - 根视图

struct PopoverRootView: View {
    @ObservedObject var vm: PopoverViewModel

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(nsColor: Design.backgroundDark).opacity(0.8))
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.top, 10)
                        .padding(.horizontal, 14)
                }
                bottomBar
            }
            if vm.theme.scanlines {
                ScanlineShape().allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        LinearGradient(colors: [Color(nsColor: vm.theme.accent).opacity(0.7),
                                Color(nsColor: vm.theme.accent).opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 3)
            .padding(.bottom, 8)

        Text(vm.greeting)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(nsColor: Design.textMuted))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 6)

        if let today = vm.today {
            TodayCard(vm: vm, today: today)
                .padding(.bottom, 10)
        } else {
            popoverCard {
                Text(L("暂无数据\n请检查设置里的数据源连接"))
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 10)
        }

        if !vm.models.isEmpty {
            ModelCard(vm: vm)
                .padding(.bottom, 8)
        }

        if vm.yesterday != nil || vm.week != nil || vm.month != nil || vm.total != nil {
            trendSection
        }

        Rectangle()
            .fill(Color(nsColor: Design.separatorColor))
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    // MARK: 今日每小时 sparkline（垫在趋势列表背后，隐晦版）

    /// 细线 + 极淡渐变、无坐标轴；点它进每小时详情
    private var hourlySparkline: some View {
        Chart {
            ForEach(vm.todayHourly) { p in
                AreaMark(x: .value(L("时间"), p.hourDate),
                         y: .value(L("Token"), p.token))
                    .foregroundStyle(.linearGradient(
                        colors: [Color.white.opacity(0.05), Color.white.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value(L("时间"), p.hourDate),
                         y: .value(L("Token"), p.token))
                    .foregroundStyle(Color.white.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 118)
        // 两端渐隐，收掉面积填充的生硬边缘
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .white, location: 0.05),
            .init(color: .white, location: 0.94),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .onTapGesture { PopoverActions.shared.openHourlyToday() }
    }

    // MARK: 今日卡片

    private struct TodayCard: View {
        @ObservedObject var vm: PopoverViewModel
        let today: DayStats

        var body: some View {
            popoverCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                        Text(L("今日用量"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(nsColor: Design.textPrimary))
                        Spacer()
                        Text("›").font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(nsColor: Design.textMuted))
                    }

                    Text(Design.formatTokens(today.total))
                        .font(.system(size: vm.theme.bigNumberFontSize,
                                      weight: swiftUIFontWeight(vm.theme.bigNumberWeight),
                                      design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color(nsColor: Design.bigNumberColor))
                        .shadow(color: Color(nsColor: Design.bigNumberColor).opacity(vm.theme.glowAlpha),
                                radius: vm.theme.glowRadius)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.35), value: today.total)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .center, spacing: 0) {
                        statColumn(L("请求数"), "\(today.reqs)", Design.textPrimary)
                        statColumn(L("缓存命中"), cacheRateText, cacheRateColor)
                        if let h = vm.workHours {
                            statColumn(L("工时"), String(format: "%.1fh", h), Design.textPrimary)
                        }
                    }

                    if let prediction = vm.predictionText {
                        Text(prediction)
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Design.textMuted))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .onTapGesture { PopoverActions.shared.openHourlyToday() }
        }

        private var cacheRateText: String {
            let denom = today.input + today.cacheCreate + today.cacheRead
            let rate = denom > 0 ? Double(today.cacheRead) / Double(denom) * 100 : 0
            return String(format: "%.0f%%", rate)
        }

        private var cacheRateColor: NSColor {
            let denom = today.input + today.cacheCreate + today.cacheRead
            let rate = denom > 0 ? Double(today.cacheRead) / Double(denom) * 100 : 0
            return rate > 75 ? Design.successColor : Design.warningColor
        }
    }

    // MARK: 模型分布卡片

    private struct ModelCard: View {
        @ObservedObject var vm: PopoverViewModel
        private let colors = Design.modelColors()

        var body: some View {
            popoverCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                        Text(L("模型分布"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(nsColor: Design.textPrimary))
                        Spacer()
                        Text("›").font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(nsColor: Design.textMuted))
                    }
                    ForEach(Array(vm.models.prefix(4).enumerated()), id: \.offset) { i, m in
                        modelRow(index: i, model: m)
                    }
                }
            }
            .onTapGesture { PopoverActions.shared.openModelToday() }
        }

        private func modelRow(index: Int, model: ModelStat) -> some View {
            let maxTotal = vm.models.prefix(4).map { $0.total }.max() ?? 1
            let progress = maxTotal > 0 ? CGFloat(model.total) / CGFloat(maxTotal) : 0
            return VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(nsColor: colors[index % colors.count]))
                        .frame(width: 6, height: 6)
                    Text(shortModelName(model.model))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(nsColor: Design.textPrimary))
                        .lineLimit(1)
                    Spacer()
                    Text(Design.formatTokensK(model.total))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Color(nsColor: Design.textSecondary))
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(Color(nsColor: Design.brandColor))
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
                .frame(height: Design.barHeight)
            }
        }

        private func shortModelName(_ name: String) -> String {
            var s = name.lowercased()
            if let dash = s.range(of: "-", options: .backwards) {
                let after = s[dash.upperBound...]
                if after.count == 8, Int(after) != nil { s = String(s[..<dash.lowerBound]) }
            }
            for p in ["claude-", "openai-", "deepseek-", "google-"] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                break
            }
            return s.count > 14 ? String(s.prefix(14)) + "…" : s
        }
    }

    // MARK: 趋势

    private var trendSection: some View {
        let tc = vm.theme.trendIconColors
        return VStack(alignment: .leading, spacing: 0) {
            Text(L("趋势"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: Design.textPrimary))
                .padding(.bottom, 2)
            // 今日逐时 sparkline 垫底：隐晦地透出今天的节奏，不抢数据的戏
            ZStack {
                if vm.todayHourly.count > 1 {
                    hourlySparkline
                        .padding(.leading, -4)
                        .padding(.trailing, -2)
                }
                VStack(spacing: 0) {
                    if let y = vm.yesterday {
                        trendRow(icon: "calendar", color: tc.yesterday, title: L("昨日"),
                                 value: Design.formatTokens(y.total), action: PopoverActions.shared.openHourlyYesterday)
                    }
                    if let w = vm.week {
                        trendRow(icon: "chart.bar", color: tc.week, title: L("近7天"),
                                 value: Design.formatTokens(w.total), action: PopoverActions.shared.openWeek)
                    }
                    if let m = vm.month {
                        trendRow(icon: "calendar.badge.clock", color: tc.month, title: L("近30天"),
                                 value: Design.formatTokens(m.total), action: PopoverActions.shared.openMonth)
                    }
                    if let t = vm.total {
                        trendRow(icon: "sum", color: tc.total, title: L("历史总量"),
                                 value: Design.formatTokens(t.total), action: PopoverActions.shared.openMonth)
                    }
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func trendRow(icon: String, color: NSColor, title: String, value: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: color))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: Design.textPrimary))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.dataHighlightColor))
            Text("›").font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(nsColor: Design.textMuted))
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    // MARK: 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 6) {
            BarActionButton(icon: "arrow.clockwise", label: L("刷新"), action: PopoverActions.shared.refresh)
            BarActionButton(icon: "chart.xyaxis.line", label: L("洞察"), action: PopoverActions.shared.insights)
            BarActionButton(icon: "gearshape", label: L("设置"), action: PopoverActions.shared.settings)
            BarActionButton(icon: "xmark", label: L("退出"), action: PopoverActions.shared.quit)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private struct BarActionButton: View {
        let icon: String
        let label: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 2) {
                    Image(systemName: icon).font(.system(size: 13))
                    Text(label).font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(Color(nsColor: Design.textSecondary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: hovering ? Design.activeFill : Design.cardFillDark)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: Design.cardBorderDark), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

}

// MARK: - 通用卡片容器（文件级，供嵌套子视图共用）

private func popoverCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
            .strokeBorder(Color(nsColor: Design.cardBorderDark), lineWidth: 0.5))
}

/// NSFont.Weight → SwiftUI Font.Weight
private func swiftUIFontWeight(_ w: NSFont.Weight) -> Font.Weight {
    switch w {
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .heavy: return .heavy
    case .black: return .black
    case .light: return .light
    default: return .bold
    }
}

private func statColumn(_ label: String, _ value: String, _ color: NSColor) -> some View {
    VStack(spacing: 3) {
        Text(label)
            .font(.system(size: 10))
            .foregroundColor(Color(nsColor: Design.textMuted))
        Text(value)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundColor(Color(nsColor: color))
    }
    .frame(maxWidth: .infinity)
}

// MARK: - CRT 扫描线

struct ScanlineShape: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                var y: CGFloat = 0
                while y < geo.size.height {
                    p.addRect(CGRect(x: 0, y: y, width: geo.size.width, height: 1))
                    y += 3
                }
            }
            .fill(Color.black.opacity(0.10))
        }
    }
}
