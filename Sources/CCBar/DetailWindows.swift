import Cocoa
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 详情窗口（SwiftUI）
//
// 原 AppKit 手写约束版整体换 SwiftUI：导航栏/表格/图表由声明式布局渲染，
// 控制器只负责 SQL 查询与数据组装（口径与旧版逐字段一致）。
// 手写约束时代的"行被压塌/按钮被挤出"类 bug 在此绝根。

/// 表格单元格（首列左对齐、其余右对齐——与旧版口径一致）
struct DetailCell: Identifiable {
    let id = UUID()
    let text: String
    let width: CGFloat
    let bold: Bool
    let color: Color
    let alignment: TextAlignment

    init(text: String, width: CGFloat, bold: Bool = false,
         color: Color, alignment: TextAlignment? = nil) {
        self.text = text
        self.width = width
        self.bold = bold
        self.color = color
        self.alignment = alignment ?? .trailing
    }
}

/// 表格行（isHeader 时用 10pt 半粗小字、22pt 行高；highlight 行铺主题色淡底）
struct DetailRow: Identifiable {
    let id = UUID()
    let cells: [DetailCell]
    let isHeader: Bool
    let highlight: Bool

    init(cells: [DetailCell], isHeader: Bool = false, highlight: Bool = false) {
        self.cells = cells
        self.isHeader = isHeader
        self.highlight = highlight
    }
}

/// 顶部统计卡片（大数字 + 小标签）
struct DetailStat: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var accent: NSColor = Design.dataHighlightColor

    init(label: String, value: String, accent: NSColor = Design.dataHighlightColor) {
        self.label = label
        self.value = value
        self.accent = accent
    }
}

/// 图表种类（各详情窗口的头部图形）
enum DetailChartSpec {
    case trend([ChartEntry])                  // 近7天：面积 + 折线
    case bars([ChartEntry], showXAxis: Bool)  // 柱状图（拖选读数）
    case donut([DonutChartWithLegendView.Item])
}

/// 内容块（id 由 DetailContentModel.set 按序号分配）
struct DetailBlock: Identifiable {
    var id: Int
    let kind: Kind

    enum Kind {
        case statCards([DetailStat])
        case chart(DetailChartSpec, height: CGFloat)
        case separator
        case rows([DetailRow])
        case empty(String)
    }
}

/// 详情窗口共享的内容模型：控制器填充，视图观察
@MainActor
final class DetailContentModel: ObservableObject {
    @Published var dateText = ""
    @Published var blocks: [DetailBlock] = []

    func set(_ kinds: [DetailBlock.Kind]) {
        blocks = kinds.enumerated().map { DetailBlock(id: $0.offset, kind: $0.element) }
    }
}

// MARK: - 根视图

struct DetailRootView: View {
    @ObservedObject var model: DetailContentModel
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onExport: (() -> Void)?
    var onToday: (() -> Void)?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(nsColor: Design.backgroundDark).opacity(0.8))
            VStack(spacing: 0) {
                navBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.blocks) { block in
                            blockView(block.kind)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var navBar: some View {
        HStack(spacing: 8) {
            Text(model.dateText)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(nsColor: Design.textPrimary))
            Spacer()
            if let onToday {
                Button(action: onToday) {
                    Text(L("回到今天"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: Design.brandColor))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: Design.brandColor).opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            if let onPrev {
                navButton("chevron.left", action: onPrev)
            }
            if let onExport {
                navButton("square.and.arrow.up", action: onExport)
            }
            if let onNext {
                navButton("chevron.right", action: onNext)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        NavCircleButton(symbol: symbol, action: action)
    }

    @ViewBuilder
    private func blockView(_ kind: DetailBlock.Kind) -> some View {
        switch kind {
        case .statCards(let stats):
            HStack(spacing: 8) {
                ForEach(stats) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Design.textMuted))
                        Text(s.value)
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                            .foregroundColor(Color(nsColor: s.accent))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
                        .fill(Color(nsColor: Design.cardFillDark)))
                    .overlay(RoundedRectangle(cornerRadius: Design.cardCornerRadius)
                        .strokeBorder(Color(nsColor: Design.cardBorderDark), lineWidth: 0.5))
                }
            }
            .padding(.vertical, 2)
        case .chart(let spec, let height):
            chartView(spec)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .separator:
            Rectangle()
                .fill(Color(nsColor: Design.separatorColor))
                .frame(height: 1)
        case .rows(let rows):
            ForEach(rows) { RowView(row: $0) }
        case .empty(let text):
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 22))
                    .foregroundColor(Color(nsColor: Design.textMuted).opacity(0.6))
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    @ViewBuilder
    private func chartView(_ spec: DetailChartSpec) -> some View {
        switch spec {
        case .trend(let entries):
            LineTrendChart(entries: entries)
        case .bars(let entries, let showXAxis):
            BarReadoutChart(entries: entries, showXAxis: showXAxis)
        case .donut(let items):
            DonutLegendRepresenter(items: items)
        }
    }

    /// 表格行：hover 微亮，highlight 行铺主题色淡底（峰值日）
    private struct RowView: View {
        let row: DetailRow
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 0) {
                ForEach(row.cells) { cell in
                    Text(cell.text)
                        .font(row.isHeader
                              ? .system(size: 10, weight: .semibold)
                              : .system(size: cell.bold ? 12 : 11,
                                        weight: cell.bold ? .bold : .medium).monospacedDigit())
                        .foregroundColor(cell.color)
                        .lineLimit(1)
                        .frame(width: cell.width, alignment: cell.alignment == .leading ? .leading : .trailing)
                        .padding(.leading, cell.alignment == .trailing ? 8 : 0)
                }
                Spacer(minLength: 0)
            }
            .frame(height: row.isHeader ? 22 : 24)
            .padding(.horizontal, row.highlight || hovering ? 5 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(row.highlight ? Color(nsColor: Design.brandColor).opacity(0.10)
                          : hovering ? Color.white.opacity(0.04) : Color.clear)
            )
            .onHover { hovering = $0 }
        }
    }
}

/// 导航圆形按钮（hover 反馈）
private struct NavCircleButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: hovering ? Design.textPrimary : Design.textSecondary))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(nsColor: hovering ? Design.activeFill : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 环形图 + 图例（AppKit 自绘视图桥接进 SwiftUI）
struct DonutLegendRepresenter: NSViewRepresentable {
    let items: [DonutChartWithLegendView.Item]

    func makeNSView(context: Context) -> DonutChartWithLegendView {
        let view = DonutChartWithLegendView(frame: .zero)
        view.items = items
        return view
    }

    func updateNSView(_ view: DonutChartWithLegendView, context: Context) {
        view.items = items
    }
}

// MARK: - 基类（查询辅助 + 行构造，口径与旧版一致）

class DetailBaseWindowController: NSWindowController {
    let content = DetailContentModel()

    /// 装配 SwiftUI 内容视图；导航/导出/回到今天由子类闭包提供
    func installContent(onPrev: (() -> Void)? = nil,
                        onNext: (() -> Void)? = nil,
                        onExport: (() -> Void)? = nil,
                        onToday: (() -> Void)? = nil) {
        window?.contentViewController = NSHostingController(
            rootView: DetailRootView(model: content, onPrev: onPrev, onNext: onNext,
                                     onExport: onExport, onToday: onToday))
    }

    func detailCell(_ text: String, _ width: CGFloat, _ color: NSColor,
                    bold: Bool = false, leading: Bool = false) -> DetailCell {
        DetailCell(text: text, width: width, bold: bold,
                   color: Color(nsColor: color), alignment: leading ? .leading : .trailing)
    }

    /// 数据行（日期/名称, 请求, 总Token, 缓存读）——各窗口共用同套配色口径。
    /// highlight = 峰值行（主题色淡底）；markToday = 今天（首列主题色）
    func dataRow(col0: String, reqs: Int, token: Int64, cache: Int64, widths: [CGFloat],
                 highlight: Bool = false, markToday: Bool = false) -> DetailRow {
        DetailRow(cells: [
            detailCell(col0, widths[0],
                       markToday ? Design.brandColor : (token == 0 ? Design.textMuted : Design.dataHighlightColor),
                       bold: markToday, leading: true),
            detailCell(reqs == 0 ? "-" : "\(reqs)", widths[1], reqs == 0 ? Design.textMuted : Design.textPrimary),
            detailCell(fmtNum(token), widths[2], token == 0 ? Design.textMuted : Design.textPrimary),
            detailCell(fmtNum(cache), widths[3], cache == 0 ? Design.textMuted : Design.textSecondary)
        ], highlight: highlight)
    }

    func totalRow(_ label: String, reqs: Int, token: Int64, cache: Int64, widths: [CGFloat]) -> DetailRow {
        DetailRow(cells: [
            detailCell(label, widths[0], Design.textPrimary, bold: true, leading: true),
            detailCell("\(reqs)", widths[1], Design.textPrimary, bold: true),
            detailCell(fmtNum(token), widths[2], Design.textPrimary, bold: true),
            detailCell(fmtNum(cache), widths[3], Design.textPrimary, bold: true)
        ])
    }

    func tableHeader(_ labels: [String], widths: [CGFloat]) -> DetailBlock.Kind {
        .rows([DetailRow(cells: labels.enumerated().map { i, text in
            detailCell(text, widths[i], Design.textMuted, leading: i == 0)
        }, isHeader: true)])
    }

    // MARK: 查询辅助

    /// 某一天的实时聚合：请求数 / 总 Token / 缓存读（daysAgo=0 表示今天）。
    /// 走统一的 usage_all；epoch 区间 + 参数绑定让 created_at 索引可用。
    /// 注意 daily_agg 不含今天，所以历史日期请用 queryDailyRows，本方法只用于今天。
    func queryDay(db: OpaquePointer, daysAgo: Int) -> (Int, Int64, Int64) {
        let sql = """
        SELECT COALESCE(SUM(request_count),0), COALESCE(SUM(output_tokens+input_tokens+cache_read_tokens+cache_creation_tokens),0),
            COALESCE(SUM(cache_read_tokens),0)
        FROM usage_all WHERE created_at >= ? AND created_at < ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, StatsStore.localMidnight(daysAgo))
        sqlite3_bind_int64(stmt, 2, StatsStore.localMidnight(daysAgo - 1))
        var result = (0, Int64(0), Int64(0))
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = (Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2))
        }
        return result
    }

    /// 一次拉取 [fromDay, toDay] 的每日汇总（daily_agg，date → 请求数/总Token/缓存读），
    /// 替代逐日循环查询；今天不在其中，调用方用 queryDay 实时补当天
    func queryDailyRows(db: OpaquePointer, fromDay: String, toDay: String) -> [String: (reqs: Int, token: Int64, cache: Int64)] {
        let sql = """
        SELECT date, COALESCE(SUM(reqs),0),
            COALESCE(SUM(input+output+cache_create+cache_read),0), COALESCE(SUM(cache_read),0)
        FROM daily_agg WHERE date >= ? AND date <= ? GROUP BY date
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        for (i, s) in [fromDay, toDay].enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [String: (reqs: Int, token: Int64, cache: Int64)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] =
                (Int(sqlite3_column_int64(stmt, 1)), sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3))
        }
        return out
    }

    /// 把当前窗口表格数据导出为 CSV（带 BOM，Excel 直接打开不乱码）
    func exportCSV(defaultName: String, header: [String], rows: [[String]]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "\u{FEFF}" + header.joined(separator: ",") + "\n"
        for row in rows {
            csv += row.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("导出失败")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: L("好的"))
            alert.runModal()
        }
    }

    func fmtNum(_ n: Int64) -> String {
        n == 0 ? "-" : L10n.formatTokens(n)
    }
}

// MARK: - 7天详情窗口

class DetailWindowController: DetailBaseWindowController {
    var currentWeekStart: Date = Date()
    var onDateChange: ((Date) -> Void)?
    private var exportRows: [[String]] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 402),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("近7天用量")
        window.center()
        window.setFrameAutosaveName("CCBarWeekDetail")
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 420, height: 250)
        self.init(window: window)
        installContent(onPrev: { [weak self] in self?.goPrevWeek() },
                       onNext: { [weak self] in self?.goNextWeek() },
                       onExport: { [weak self] in self?.exportCSVClicked() },
                       onToday: { [weak self] in self?.goThisWeek() })
    }

    func goPrevWeek() {
        currentWeekStart = Calendar.current.date(byAdding: .day, value: -7, to: currentWeekStart)!
        onDateChange?(currentWeekStart)
    }

    func goNextWeek() {
        let next = Calendar.current.date(byAdding: .day, value: 7, to: currentWeekStart)!
        if next <= Date() { currentWeekStart = next; onDateChange?(next) }
    }

    /// 回到本周（周一起始，与打开时的口径一致）
    func goThisWeek() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let monday = cal.date(byAdding: .day, value: -(weekday - 2), to: today)!
        currentWeekStart = monday
        onDateChange?(monday)
    }

    func reloadData(db: OpaquePointer?, weekStart: Date) {
        guard let db = db else { return }
        currentWeekStart = weekStart

        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd"
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        content.dateText = "\(fmt.string(from: weekStart))  ~  \(fmt.string(from: end))"

        let widths: [CGFloat] = [70, 65, 95, 95]
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayKey = DateFormatter(); dayKey.dateFormat = "yyyy-MM-dd"
        var totalReqs = 0; var totalToken: Int64 = 0; var totalCache: Int64 = 0
        var chartEntries: [ChartEntry] = []
        var dayRows: [DetailRow] = []
        exportRows = []

        // 整周一次从 daily_agg 拉历史，今天实时补查（daily_agg 不含今天）
        let endOfWeek = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let agg = queryDailyRows(db: db, fromDay: dayKey.string(from: weekStart),
                                 toDay: dayKey.string(from: endOfWeek))

        var dayData: [(dateStr: String, reqs: Int, token: Int64, cache: Int64, daysAgo: Int)] = []
        for d in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: d, to: weekStart) else { continue }
            let dateStr = dayKey.string(from: date)
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: today).day ?? 0
            var reqs = 0; var token = Int64(0); var cache = Int64(0)
            if daysAgo == 0 {
                (reqs, token, cache) = queryDay(db: db, daysAgo: 0)
            } else if let a = agg[dateStr] {
                reqs = a.reqs; token = a.token; cache = a.cache
            }
            totalReqs += reqs; totalToken += token; totalCache += cache
            dayData.append((dateStr, reqs, token, cache, daysAgo))
            chartEntries.append(ChartEntry(label: String(dateStr.suffix(5)), value: token))
        }

        let peakToken = dayData.map(\.token).max() ?? 0
        let daysWithData = dayData.filter { $0.token > 0 }.count
        let dailyAvg = daysWithData > 0 ? totalToken / Int64(daysWithData) : 0
        for e in dayData {
            exportRows.append([e.dateStr, "\(e.reqs)", "\(e.token)", "\(e.cache)"])
            dayRows.append(dataRow(col0: e.dateStr, reqs: e.reqs, token: e.token, cache: e.cache,
                                   widths: widths,
                                   highlight: peakToken > 0 && e.token == peakToken,
                                   markToday: e.daysAgo == 0))
        }

        content.set([
            .statCards([
                DetailStat(label: L("总 Token"), value: Design.formatTokens(totalToken)),
                DetailStat(label: L("日均"), value: Design.formatTokens(dailyAvg)),
                DetailStat(label: L("请求数"), value: "\(totalReqs)"),
                DetailStat(label: L("缓存读"), value: Design.formatTokens(totalCache)),
            ]),
            .chart(.trend(chartEntries), height: 90),
            .separator,
            tableHeader([L("日期"), L("请求"), L("总 Token"), L("缓存读")], widths: widths),
            .separator,
            .rows(dayRows),
            .separator,
            .rows([totalRow(L("合计"), reqs: totalReqs, token: totalToken, cache: totalCache, widths: widths)])
        ])
    }

    func exportCSVClicked() {
        exportCSV(defaultName: L("ccbar-近7天.csv"),
                  header: [L("日期"), L("请求数"), L("总Token"), L("缓存读")],
                  rows: exportRows)
    }
}

// MARK: - 30天详情窗口

class MonthDetailWindowController: DetailBaseWindowController {
    var currentMonth: Date = Date()
    var db: OpaquePointer?
    private var exportRows: [[String]] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 606),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("近30天用量")
        window.center()
        window.setFrameAutosaveName("CCBarMonthDetail")
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 420, height: 300)
        self.init(window: window)
        installContent(onPrev: { [weak self] in self?.goPrevMonth() },
                       onNext: { [weak self] in self?.goNextMonth() },
                       onExport: { [weak self] in self?.exportCSVClicked() },
                       onToday: { [weak self] in self?.goThisMonth() })
    }

    func goPrevMonth() {
        currentMonth = Calendar.current.date(byAdding: .month, value: -1, to: currentMonth)!
        reloadData()
    }

    func goNextMonth() {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: currentMonth)!
        if next <= Date() { currentMonth = next; reloadData() }
    }

    func goThisMonth() {
        currentMonth = Date()
        reloadData()
    }

    func reloadData() {
        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM"
        content.dateText = fmt.string(from: currentMonth)
        guard let db = self.db else { return }

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: currentMonth)
        let first = cal.date(from: comps)!
        let days = cal.range(of: .day, in: .month, for: currentMonth)!.count

        let widths: [CGFloat] = [70, 65, 95, 95]
        let today = cal.startOfDay(for: Date())
        let dayKey = DateFormatter(); dayKey.dateFormat = "yyyy-MM-dd"
        var totalReqs = 0; var totalToken: Int64 = 0; var totalCache: Int64 = 0
        var chartEntries: [ChartEntry] = []
        var dayRows: [DetailRow] = []
        exportRows = []

        // 整月一次从 daily_agg 拉历史，今天实时补查（daily_agg 不含今天）
        let lastDay = cal.date(byAdding: .day, value: days - 1, to: first) ?? first
        let agg = queryDailyRows(db: db, fromDay: dayKey.string(from: first),
                                 toDay: dayKey.string(from: lastDay))

        var dayData: [(dateStr: String, keyStr: String, reqs: Int, token: Int64, cache: Int64, daysAgo: Int)] = []
        for day in 1...days {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: first) else { continue }
            if cal.startOfDay(for: date) > today { break }
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: today).day ?? 0
            let keyStr = dayKey.string(from: date)
            var reqs = 0; var token = Int64(0); var cache = Int64(0)
            if daysAgo == 0 {
                (reqs, token, cache) = queryDay(db: db, daysAgo: 0)
            } else if let a = agg[keyStr] {
                reqs = a.reqs; token = a.token; cache = a.cache
            }
            totalReqs += reqs; totalToken += token; totalCache += cache
            let dateStr = String(format: "%02d/%02d", comps.month!, day)
            dayData.append((dateStr, keyStr, reqs, token, cache, daysAgo))
            chartEntries.append(ChartEntry(label: dateStr, value: token))
        }

        let peakToken = dayData.map(\.token).max() ?? 0
        let daysWithData = dayData.filter { $0.token > 0 }.count
        let dailyAvg = daysWithData > 0 ? totalToken / Int64(daysWithData) : 0
        for e in dayData {
            exportRows.append([e.keyStr, "\(e.reqs)", "\(e.token)", "\(e.cache)"])
            dayRows.append(dataRow(col0: e.dateStr, reqs: e.reqs, token: e.token, cache: e.cache,
                                   widths: widths,
                                   highlight: peakToken > 0 && e.token == peakToken,
                                   markToday: e.daysAgo == 0))
        }

        content.set([
            .statCards([
                DetailStat(label: L("总 Token"), value: Design.formatTokens(totalToken)),
                DetailStat(label: L("日均"), value: Design.formatTokens(dailyAvg)),
                DetailStat(label: L("请求数"), value: "\(totalReqs)"),
                DetailStat(label: L("缓存读"), value: Design.formatTokens(totalCache)),
            ]),
            .chart(.bars(chartEntries, showXAxis: false), height: 100),
            .separator,
            tableHeader([L("日期"), L("请求"), L("总 Token"), L("缓存读")], widths: widths),
            .separator,
            .rows(dayRows),
            .separator,
            .rows([totalRow(L("合计"), reqs: totalReqs, token: totalToken, cache: totalCache, widths: widths)])
        ])
    }

    func exportCSVClicked() {
        exportCSV(defaultName: L("ccbar-近30天.csv"),
                  header: [L("日期"), L("请求数"), L("总Token"), L("缓存读")],
                  rows: exportRows)
    }
}

// MARK: - 模型分布详情窗口

class ModelDetailWindowController: DetailBaseWindowController {
    var currentDate: Date = Date()
    var onDateChange: ((Date) -> Void)?
    var db: OpaquePointer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 466),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("模型分布详情")
        window.center()
        window.setFrameAutosaveName("CCBarModelDetail")
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 460, height: 300)
        self.init(window: window)
        installContent(onPrev: { [weak self] in self?.goPrevDay() },
                       onNext: { [weak self] in self?.goNextDay() })
    }

    func goPrevDay() {
        currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate)!
        onDateChange?(currentDate)
    }

    func goNextDay() {
        let t = Calendar.current.date(byAdding: .day, value: 1, to: currentDate)!
        if t <= Date() { currentDate = t; onDateChange?(t) }
    }

    func reloadData(db: OpaquePointer?, date: Date) {
        guard let db = db else { return }
        currentDate = date
        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd"
        content.dateText = fmt.string(from: date)

        let cal = Calendar.current
        let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0

        let sql = """
        SELECT source, model, COALESCE(SUM(request_count),0),
            COALESCE(SUM(input_tokens+output_tokens+cache_read_tokens+cache_creation_tokens),0),
            COALESCE(SUM(cache_read_tokens),0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY source, model ORDER BY 4 DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, StatsStore.localMidnight(daysAgo))
        sqlite3_bind_int64(stmt, 2, StatsStore.localMidnight(daysAgo - 1))
        var rows: [(source: String, model: String, reqs: Int, token: Int64, cache: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((String(cString: sqlite3_column_text(stmt, 0)),
                         String(cString: sqlite3_column_text(stmt, 1)),
                         Int(sqlite3_column_int64(stmt, 2)),
                         sqlite3_column_int64(stmt, 3),
                         sqlite3_column_int64(stmt, 4)))
        }
        sqlite3_finalize(stmt)

        if rows.isEmpty {
            content.set([.empty(L("暂无数据"))])
            return
        }

        // 环形图：跨渠道按模型合并，展示整体分布
        var merged: [String: (token: Int64, cache: Int64)] = [:]
        for r in rows {
            let m = merged[r.model] ?? (0, 0)
            merged[r.model] = (m.token + r.token, m.cache + r.cache)
        }
        let donutModels = merged.sorted { $0.value.token > $1.value.token }
        let totalToken = donutModels.reduce(Int64(0)) { $0 + $1.value.token }

        let colors = Design.modelColors()
        let donutItems = donutModels.prefix(6).enumerated().map { i, e -> DonutChartWithLegendView.Item in
            let pct = totalToken > 0 ? String(format: "%.1f%%", Double(e.value.token) / Double(totalToken) * 100) : "0%"
            return DonutChartWithLegendView.Item(value: CGFloat(e.value.token),
                                                 color: colors[i % colors.count],
                                                 label: shortModelName(e.key),
                                                 percentage: pct)
        }

        let widths: [CGFloat] = [160, 65, 100, 100]
        let topShare = totalToken > 0
            ? Double(donutModels.first?.value.token ?? 0) / Double(totalToken) * 100 : 0
        var blocks: [DetailBlock.Kind] = [
            .statCards([
                DetailStat(label: L("总 Token"), value: Design.formatTokens(totalToken)),
                DetailStat(label: L("模型数"), value: "\(donutModels.count)"),
                DetailStat(label: L("Top1 占比"), value: String(format: "%.0f%%", topShare),
                           accent: Design.warningColor),
            ]),
            .chart(.donut(donutItems), height: 140),
            .separator,
            tableHeader([L("模型"), L("请求"), L("总 Token"), L("缓存读")], widths: widths)
        ]

        // 表格按渠道分组（渠道按各自总量降序）
        var groupOrder: [String] = []
        var groups: [String: [(model: String, reqs: Int, token: Int64, cache: Int64)]] = [:]
        for r in rows {
            if groups[r.source] == nil {
                groupOrder.append(r.source)
                groups[r.source] = []
            }
            groups[r.source]?.append((r.model, r.reqs, r.token, r.cache))
        }
        groupOrder.sort {
            groups[$0]!.reduce(Int64(0)) { $0 + $1.token } > groups[$1]!.reduce(Int64(0)) { $0 + $1.token }
        }

        var totR = 0; var totT: Int64 = 0; var totC: Int64 = 0
        for source in groupOrder {
            let models = groups[source]!
            let srcToken = models.reduce(Int64(0)) { $0 + $1.token }

            // 渠道小节头：渠道名 + 该渠道总 Token
            blocks.append(.rows([DetailRow(cells: [
                detailCell("● \(AppDelegate.shared?.sourceDisplayName(source) ?? source)", widths[0], Design.brandColor, bold: true, leading: true),
                detailCell("", widths[1], Design.textMuted),
                detailCell(fmtNum(srcToken), widths[2], Design.dataHighlightColor, bold: true),
                detailCell("", widths[3], Design.textMuted)
            ])]))

            var modelRows: [DetailRow] = []
            for m in models {
                totR += m.reqs; totT += m.token; totC += m.cache
                modelRows.append(dataRow(col0: shortModelName(m.model), reqs: m.reqs,
                                         token: m.token, cache: m.cache, widths: widths))
            }
            blocks.append(.rows(modelRows))
        }

        blocks.append(.separator)
        blocks.append(.rows([totalRow(L("合计"), reqs: totR, token: totT, cache: totC, widths: widths)]))
        content.set(blocks)
    }

    private func shortModelName(_ name: String) -> String {
        var s = name.lowercased()
        if let r = s.range(of: "-", options: .backwards) {
            let after = s[r.upperBound...]
            if after.count == 8, Int(after) != nil { s = String(s[..<r.lowerBound]) }
        }
        for p in ["claude-", "openai-", "deepseek-", "google-"] {
            if s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        }
        if s.count > 18 { s = String(s.prefix(18)) + "…" }
        return s
    }
}

// MARK: - 每小时详情窗口

class HourlyDetailWindowController: DetailBaseWindowController {
    var currentDate: Date = Date()
    var onDateChange: ((Date) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("每小时用量")
        window.center()
        window.setFrameAutosaveName("CCBarHourlyDetail")
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 360, height: 300)
        self.init(window: window)
        installContent(onPrev: { [weak self] in self?.goPrevDay() },
                       onNext: { [weak self] in self?.goNextDay() },
                       onToday: { [weak self] in self?.goToday() })
    }

    func goPrevDay() {
        currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate)!
        onDateChange?(currentDate)
    }

    func goNextDay() {
        let t = Calendar.current.date(byAdding: .day, value: 1, to: currentDate)!
        if t <= Date() { currentDate = t; onDateChange?(t) }
    }

    func goToday() {
        currentDate = Date()
        onDateChange?(currentDate)
    }

    func reloadData(db: OpaquePointer?, date: Date) {
        guard let db = db else { return }
        currentDate = date
        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd"
        content.dateText = fmt.string(from: date)

        let cal = Calendar.current
        let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0

        var hourly: [(Int, Int64, Int64, Int64, Int64)] = Array(repeating: (0, 0, 0, 0, 0), count: 24)
        let sql = """
        SELECT strftime('%H',created_at,'unixepoch','localtime'), COALESCE(SUM(request_count),0),
            COALESCE(SUM(output_tokens+input_tokens+cache_read_tokens+cache_creation_tokens),0),
            COALESCE(SUM(cache_read_tokens),0),
            COALESCE(SUM(cache_creation_tokens),0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY 1 ORDER BY 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, StatsStore.localMidnight(daysAgo))
        sqlite3_bind_int64(stmt, 2, StatsStore.localMidnight(daysAgo - 1))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let hs = sqlite3_column_text(stmt, 0) {
                let h = Int(String(cString: hs)) ?? 0
                if h >= 0 && h < 24 {
                    hourly[h] = (Int(sqlite3_column_int(stmt, 1)), sqlite3_column_int64(stmt, 2),
                                 sqlite3_column_int64(stmt, 3), sqlite3_column_int64(stmt, 4), 0)
                }
            }
        }
        sqlite3_finalize(stmt)

        // 找有数据的小时范围
        var start = 23, end = 0
        for h in 0..<24 {
            if hourly[h].0 > 0 || hourly[h].1 > 0 {
                if h < start { start = h }; if h > end { end = h }
            }
        }
        if start > end {
            content.set([.empty(L("暂无数据"))])
            return
        }

        var totR = 0; var totT: Int64 = 0; var totC: Int64 = 0
        var peakHour = start
        for h in start...end {
            let d = hourly[h]; totR += d.0; totT += d.1; totC += d.2
            if d.1 > hourly[peakHour].1 { peakHour = h }
        }

        let widths: [CGFloat] = [50, 65, 100, 100]
        var hourRows: [DetailRow] = []
        for h in start...end {
            let d = hourly[h]
            hourRows.append(dataRow(col0: L10n.isEnglish ? String(format: "%02d:00", h) : "\(h)时",
                                    reqs: d.0, token: d.1, cache: d.2, widths: widths,
                                    highlight: d.1 > 0 && h == peakHour,
                                    markToday: daysAgo == 0))
        }

        content.set([
            .statCards([
                DetailStat(label: L("总 Token"), value: Design.formatTokens(totT)),
                DetailStat(label: L("请求数"), value: "\(totR)"),
                DetailStat(label: L("峰值时段"),
                           value: L10n.isEnglish ? String(format: "%02d:00", peakHour) : "\(peakHour)时",
                           accent: Design.warningColor),
            ]),
            .chart(.bars((0..<24).map { ChartEntry(label: String(format: "%02d", $0), value: hourly[$0].1) },
                         showXAxis: true), height: 100),
            .separator,
            .rows([totalRow(L("合计"), reqs: totR, token: totT, cache: totC, widths: widths)]),
            .separator,
            tableHeader([L("时间"), L("请求"), L("总 Token"), L("缓存读")], widths: widths),
            .separator,
            .rows(hourRows)
        ])

        // 内容高度 = 统计卡 ≈50 + 图表 100 + 表头/合计/分隔 ≈ 71 + 每行 24；
        // 再加导航/留白 56（顶 10 + 导航 30 + 间隔 6 + 底 10）。
        let h = CGFloat(end - start + 1) * 24 + 277
        window?.setContentSize(NSSize(width: 440, height: min(h, 680)))
    }
}

// MARK: - 历史总量窗口（按月汇总）

class AllTimeDetailWindowController: DetailBaseWindowController {
    private var exportRows: [[String]] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 526),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("历史总量")
        window.center()
        window.setFrameAutosaveName("CCBarAllTimeDetail")
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 420, height: 300)
        self.init(window: window)
        installContent(onExport: { [weak self] in self?.exportCSVClicked() })
        content.dateText = L("按月汇总")
    }

    /// db 查 daily_agg 按月汇总；today 由调用方传入实时叠加到当前月
    func reloadData(db: OpaquePointer?, today: DayStats?) {
        exportRows = []

        var rows: [(month: String, reqs: Int, token: Int64, cache: Int64)] = []
        if let store = AppDelegate.shared?.store {
            rows = store.queryMonthlyTotals(limit: 36)
        }

        // 今日实时并入当前月（daily_agg 不含今天）
        if let t = today, t.reqs > 0 || t.total > 0 {
            let month = StatsStore.dayString(fromEpoch: StatsStore.localMidnight(0)).prefix(7)
            if let idx = rows.firstIndex(where: { $0.month == month }) {
                rows[idx].reqs += t.reqs
                rows[idx].token += t.total
                rows[idx].cache += t.cacheRead
            } else {
                rows.insert((month: String(month), reqs: t.reqs, token: t.total, cache: t.cacheRead), at: 0)
            }
        }

        if rows.isEmpty {
            content.set([.empty(L("暂无数据"))])
            return
        }

        let widths: [CGFloat] = [70, 65, 95, 95]
        var monthRows: [DetailRow] = []
        var totalReqs = 0; var totalToken: Int64 = 0; var totalCache: Int64 = 0
        let peakMonthToken = rows.map(\.token).max() ?? 0
        for r in rows {
            totalReqs += r.reqs; totalToken += r.token; totalCache += r.cache
            exportRows.append([r.month, "\(r.reqs)", "\(r.token)", "\(r.cache)"])
            monthRows.append(dataRow(col0: r.month, reqs: r.reqs, token: r.token, cache: r.cache,
                                     widths: widths,
                                     highlight: peakMonthToken > 0 && r.token == peakMonthToken))
        }
        let bestMonth = rows.max { $0.token < $1.token }?.month ?? "-"

        // 图表（最近月份在上 → 图表用倒序让时间从左到右）
        let monthEntries = rows.reversed().map { ChartEntry(label: $0.month, value: $0.token) }

        content.set([
            .statCards([
                DetailStat(label: L("历史总量"), value: Design.formatTokens(totalToken)),
                DetailStat(label: L("月均"), value: Design.formatTokens(totalToken / Int64(max(rows.count, 1)))),
                DetailStat(label: L("最佳月"), value: bestMonth, accent: Design.warningColor),
                DetailStat(label: L("请求数"), value: "\(totalReqs)"),
            ]),
            .chart(.bars(monthEntries, showXAxis: true), height: 100),
            .separator,
            tableHeader([L("月份"), L("请求"), L("总 Token"), L("缓存读")], widths: widths),
            .separator,
            .rows(monthRows),
            .separator,
            .rows([totalRow(L("合计"), reqs: totalReqs, token: totalToken, cache: totalCache, widths: widths)])
        ])
    }

    func exportCSVClicked() {
        exportCSV(defaultName: L("ccbar-按月汇总.csv"),
                  header: [L("月份"), L("请求数"), L("总Token"), L("缓存读")],
                  rows: exportRows)
    }
}
