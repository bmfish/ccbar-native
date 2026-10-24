import XCTest
import SwiftUI
@testable import CCBar

/// 洞察中心五页离屏渲染冒烟测试：
/// 用真实库副本喂 VM（无副本则跳过），ImageRenderer 出 PNG 到 /tmp/insights-page-*.png
@MainActor
final class InsightsRenderTests: XCTestCase {

    func testWeeklyReportGuard() throws {
        // 二维码必须能出图（分享卡页脚用）
        let qr = QRCodeMaker.image(for: "https://github.com/bmfish/ccbar-native", pointSize: 46)
        XCTAssertNotNil(qr)
        XCTAssertEqual(qr?.size.width, 46)

        // 分享卡整卡离屏渲染必须出真实内容（防 ImageRenderer 式黑图）
        let card = weeklyShareCard(
            dateRange: "9月28日 ~ 10月4日", total: 123_000_000, reqs: 2345,
            peak: 50_000_000,
            trend: (0..<7).map { ChartEntry(label: "09-\($0)", value: Int64($0 + 1) * 100) })
        let png = ShareCardRenderer.pngData(card, width: 460)
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png?.count ?? 0, 5000, "渲染出的 PNG 太小，疑似黑图/空白")
        try png?.write(to: URL(fileURLWithPath: "/tmp/insights-page-weekly.png"))   // 本地目检用

        // 窗口口径：周一生成上周一~周日（7..1），周二预览上一个完整周（8..2）
        let monWindow = WeeklyReport.lastWeekWindow(now: Date(timeIntervalSince1970: 1_791_187_200))
        XCTAssertEqual(monWindow.from, 7)
        XCTAssertEqual(monWindow.to, 1)
        let tueWindow = WeeklyReport.lastWeekWindow(now: Date(timeIntervalSince1970: 1_791_273_600))   // 2026-10-06（周二）
        XCTAssertEqual(tueWindow.from, 8)
        XCTAssertEqual(tueWindow.to, 2)
    }

    func testPopoverHourlyAndRender() throws {
        // hourPoints：掐头（首个有数据的整点起线）+ 尾部补到当天最后、空洞补零
        var hist: [Int: Int64] = [0: 50, 23: 100]
        hist[5] = 0   // 无数据整点，不作为起点
        let points = PopoverViewModel.hourPoints(from: hist)
        XCTAssertEqual(points.count, 24)
        XCTAssertEqual(points.first?.token, 50)
        XCTAssertEqual(points.last?.token, 100)
        XCTAssertTrue(PopoverViewModel.hourPoints(from: [5: 0]).isEmpty)
        XCTAssertTrue(PopoverViewModel.hourPoints(from: [:]).isEmpty)

        // 首数据晚于 9 点：固定从 9 点起线（9 点补零）；结尾以数据最晚小时(23)封口，与运行时刻无关
        let late = PopoverViewModel.hourPoints(from: [11: 100, 23: 5])
        XCTAssertEqual(late.count, 15)          // 9...23
        XCTAssertEqual(late.first?.token, 0)    // 9 时补零
        XCTAssertEqual(late[2].token, 100)      // 11 时
        XCTAssertEqual(late.last?.token, 5)
        // 首数据早于 9 点：从首数据时刻起线
        let early = PopoverViewModel.hourPoints(from: [7: 80, 23: 10])
        XCTAssertEqual(early.count, 17)
        XCTAssertEqual(early.first?.token, 80)

        // 空的当前小时不画：线止于最后有数据的小时，不坠到零
        let trimmed = PopoverViewModel.hourPoints(from: [9: 100, 10: 200])
        XCTAssertEqual(trimmed.count, 2)        // 9...10，没有拖到当前小时的尾巴
        XCTAssertEqual(trimmed.last?.token, 200)

        // 弹窗整版离屏渲染（布局目检用）
        let vm = PopoverViewModel(greeting: "测试问候语")
        vm.today = DayStats(reqs: 90, input: 9_000_000, output: 5_000_000, cacheCreate: 100, cacheRead: 1_980_000)
        vm.yesterday = DayStats(reqs: 120, input: 52_000_000, output: 51_000_000, cacheCreate: 0, cacheRead: 1_000_000)
        vm.week = DayStats(reqs: 800, input: 200_000_000, output: 200_000_000, cacheCreate: 0, cacheRead: 5_000_000)
        vm.month = DayStats(reqs: 3400, input: 1_900_000_000, output: 1_900_000_000, cacheCreate: 0, cacheRead: 30_000_000)
        vm.total = TotalStats(reqs: 9200, total: 10_333_000_000)
        vm.models = [
            ModelStat(model: "glm-5.3-flash", input: 0, output: 0, total: 15_830_000),
            ModelStat(model: "mimo-v2.6-pro", input: 0, output: 0, total: 140_000),
        ]
        vm.workHours = 1.8
        let cal = Calendar.current
        vm.todayHourly = (9...11).map { h in
            HourPoint(hourDate: cal.date(byAdding: .hour, value: h, to: cal.startOfDay(for: Date()))!,
                      token: h == 10 ? 0 : Int64(h - 8) * 8_000_000)   // 中间夹 0，验证单调插值不断线
        }
        let v = NSHostingView(rootView: PopoverRootView(vm: vm).frame(width: 380)
            .background(Color(nsColor: Design.backgroundDark)))
        v.frame = NSRect(x: 0, y: 0, width: 380, height: 560)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds),
              let data = {
                v.cacheDisplay(in: v.bounds, to: rep)
                return rep.representation(using: .png, properties: [:])
        }() else {
            return XCTFail("弹窗渲染失败")
        }
        try data.write(to: URL(fileURLWithPath: "/tmp/popover-render.png"))
    }

    func testDetailWindowRender() throws {
        // 详情窗口新版版式：统计卡 + 图表 + 峰值行高亮 + 空态
        let model = DetailContentModel()
        model.dateText = "26-09-30  ~  26-10-06"
        let entries = (0..<7).map { d in
            ChartEntry(label: String(format: "10-%02d", d + 1), value: [3, 8, 5, 12, 6, 0, 9][d] * 100_000)
        }
        let widths: [CGFloat] = [70, 65, 95, 95]
        func cell(_ t: String, _ w: CGFloat, _ leading: Bool = false) -> DetailCell {
            DetailCell(text: t, width: w, color: .white, alignment: leading ? .leading : .trailing)
        }
        var rows: [DetailRow] = []
        for (i, e) in entries.enumerated() {
            rows.append(DetailRow(cells: [
                cell(e.label, widths[0], true), cell("\(i + 1)0", widths[1]),
                cell(Design.formatTokens(e.value), widths[2]), cell("-", widths[3]),
            ], highlight: e.value == 1_200_000))
        }
        model.set([
            .statCards([
                DetailStat(label: L("总 Token"), value: "430.00万"),
                DetailStat(label: L("日均"), value: "61.42万"),
                DetailStat(label: L("请求数"), value: "342"),
                DetailStat(label: L("缓存读"), value: "120.00万"),
            ]),
            .chart(.trend(entries), height: 90),
            .separator,
            .rows([DetailRow(cells: [cell(L("日期"), widths[0], true), cell(L("请求"), widths[1]),
                                     cell(L("总 Token"), widths[2]), cell(L("缓存读"), widths[3])], isHeader: true)]),
            .separator,
            .rows(rows),
            .separator,
            .empty(L("暂无数据")),
        ])
        let v = NSHostingView(rootView: DetailRootView(model: model).frame(width: 500)
            .background(Color(nsColor: Design.backgroundDark)))
        v.frame = NSRect(x: 0, y: 0, width: 500, height: 520)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds),
              let data = {
                v.cacheDisplay(in: v.bounds, to: rep)
                return rep.representation(using: .png, properties: [:])
        }() else {
            return XCTFail("详情窗口渲染失败")
        }
        try data.write(to: URL(fileURLWithPath: "/tmp/detail-render.png"))
    }

    func testDetailWindowsIncludeCredits() throws {
        // 各详情窗口的表格都必须带积分列、合计行含积分（早期只有 Top 会话窗口有）
        let dir = NSTemporaryDirectory() + "ccbar-detail-credits-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = StatsStore(storePath: dir + "/ccbar.db")
        store.rebuild(configs: [])
        defer { store.close() }
        let db = try XCTUnwrap(store.handle)

        let midnight = StatsStore.localMidnight(0)
        store.upsertTraeRows([
            TraeRow(sessionID: "s1", model: "claude-test", input: 100, output: 50,
                    cacheRead: 10, cacheWrite: 0, costUsd: 0.1, credits: 7.5, epoch: midnight + 3600),
            TraeRow(sessionID: "s2", model: "claude-test", input: 200, output: 80,
                    cacheRead: 20, cacheWrite: 0, costUsd: 0.2, credits: 2.25, epoch: midnight + 7200),
        ])
        let totalCredits = SettingsViewModel.fmtCredits(9.75)

        func blocks(_ content: DetailContentModel) -> [DetailRow] {
            content.blocks.flatMap { block -> [DetailRow] in
                if case .rows(let rows) = block.kind { return rows }
                return []
            }
        }
        func verify(_ content: DetailContentModel, name: String,
                    file: StaticString = #filePath, line: UInt = #line) {
            let rows = blocks(content)
            XCTAssertFalse(rows.isEmpty, "\(name): 应有表格行", file: file, line: line)
            XCTAssertEqual(rows.first(where: \.isHeader)?.cells.last?.text, L("积分"),
                           "\(name): 表头应有积分列", file: file, line: line)
            for row in rows {
                XCTAssertEqual(row.cells.count, 5, "\(name): 每行应有 5 列", file: file, line: line)
            }
            let total = rows.first { $0.cells.first?.text == L("合计") }
            XCTAssertEqual(total?.cells.last?.text, totalCredits,
                           "\(name): 合计行应含积分", file: file, line: line)
            XCTAssertTrue(rows.contains { !$0.isHeader && $0.cells.last?.text == totalCredits },
                          "\(name): 应有数据行展示积分", file: file, line: line)
        }

        let week = DetailWindowController()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let monday = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: today) - 2), to: today)!
        week.reloadData(db: store.handle, weekStart: monday)
        verify(week.content, name: "近7天")

        let month = MonthDetailWindowController()
        month.db = store.handle
        month.currentMonth = Date()
        month.reloadData()
        verify(month.content, name: "近30天")

        let model = ModelDetailWindowController()
        model.reloadData(db: store.handle, date: Date())
        verify(model.content, name: "模型分布")

        let hourly = HourlyDetailWindowController()
        hourly.reloadData(db: store.handle, date: Date())
        verify(hourly.content, name: "每小时")

        // 历史总量：按月积分走独立 SQL（daily_agg 无 credits 列）
        let base = DetailBaseWindowController(window: nil)
        let monthKey = String(StatsStore.dayString(fromEpoch: midnight).prefix(7))
        XCTAssertEqual(base.queryCreditsByMonth(db: db)[monthKey] ?? 0, 9.75, accuracy: 0.001)
    }

    func testSessionStats() throws {
        // 30 分钟间隔切会话：t0、t0+1min 一段；t0+4000s（>30min）新一段
        let base = 1_800_000_000
        let times = [base, base + 60, base + 4000]
        let (count, avgMin, longestMin) = InsightsViewModel.sessionStats(fromTimes: times)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(avgMin, 0)        // (60s + 0s)/2 = 30s → 0 分钟
        XCTAssertEqual(longestMin, 1)    // 60s → 1 分钟
        XCTAssertEqual(InsightsViewModel.sessionStats(fromTimes: []).0, 0)
    }

    func testTimelineGrouping() throws {
        // 复刻线上串组场景：20/19/12/11 点的行混杂的 DESC 序列
        let cal = Calendar.current
        let base = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        func at(_ h: Int, _ m: Int, _ s: Int) -> Int { base + h * 3600 + m * 60 + s }
        let rows: [(time: Int, model: String, source: String, token: Int64, cost: Double, credits: Double)] = [
            (at(20, 26, 50), "GLM", "zcode", 0, 0, 0),
            (at(19, 42, 10), "GLM", "zcode", 520_000, 0, 0),
            (at(19, 41, 23), "GLM", "zcode", 520_000, 0, 0),
            (at(12, 57, 54), "GLM", "zcode", 460_000, 0, 0),
            (at(12, 39, 26), "GLM", "zcode", 450_000, 0, 0),
            (at(11, 42, 38), "GLM", "zcode", 420_000, 0, 0),
            (at(11, 40, 0), "GLM", "zcode", 420_000, 0, 0),
        ]
        let lines = TimelinePage.buildLines(rows)

        // 组头恰好 4 个：20/19/12/11，各在组首行前，计数正确
        let headers = lines.compactMap { line -> (Int, Int)? in
            if case .header(let h, let c, _) = line { return (h, c) }
            return nil
        }
        XCTAssertEqual(headers.map(\.0), [20, 19, 12, 11])
        XCTAssertEqual(headers.map(\.1), [1, 2, 2, 2])
        // 组头携带整组积分合计（测试数据全为 0）
        for line in lines {
            if case .header(_, _, let credits) = line { XCTAssertEqual(credits, 0) }
        }

        // 数据行顺序保持 DESC、总数一致
        let dataRows = lines.compactMap { line -> Int? in
            if case .row(let time, _, _, _, _, _) = line { return time }
            return nil
        }
        XCTAssertEqual(dataRows, rows.map(\.time), "顺序必须保持 DESC 且不串行")

        // 每行紧随其组头之后
        for (i, line) in lines.enumerated() {
            if case .row(let time, _, _, _, _, _) = line {
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(time)))
                if case .header(let hh, _, _)? = i > 0 ? lines[i - 1] : nil {
                    XCTAssertEqual(hh, h, "行必须紧跟自己的组头")
                }
            }
        }
    }

    func testRenderAllPages() throws {
        let dbPath = "/tmp/ccbar-recheck/ccbar.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("无真实库副本，本地验证用")
        }
        let store = StatsStore(storePath: dbPath)
        let cc = CCSwitchAdapter(), zc = ZCodeAdapter()
        store.rebuild(configs: [
            SourceConfig(id: cc.id, enabled: true, dbPath: cc.defaultPath),
            SourceConfig(id: zc.id, enabled: true, dbPath: zc.defaultPath),
        ])
        store.syncIfNeeded()

        let vm = InsightsViewModel()
        vm.load(store: store, force: true)
        XCTAssertGreaterThan(vm.totalAll, 0, "VM 应有数据")
        vm.monthlyBudget = 50   // 注入预算，验证预算卡与走势图预算线（真机读自设置）

        let pages: [(String, AnyView, CGFloat)] = [
            ("cost", AnyView(CostPage(vm: vm)), 700),
            ("insights", AnyView(InsightsPageView(vm: vm)), 1350),
            ("share", AnyView(SharePage(vm: vm)), 1050),
            ("channels", AnyView(ChannelsPage(vm: vm)), 1250),
            ("timeline", AnyView(TimelinePage(vm: vm)), 500),
            ("credits", AnyView(CreditsPage(vm: vm)), 760),
            ("settings", AnyView(SettingsRootView(vm: SettingsViewModel(settings: Settings()) {})), 820),
        ]
        _ = pages.count
        // 整个根视图（含深色底）包一起渲染
        let root = InsightsRootView(vm: vm).frame(width: 720, height: 560)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("拿不到位图上下文")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/insights-root.png"))

        // 逐页：强制布局后位图缓存
        var rendered = 0
        for (name, view, height) in pages {
            let v = NSHostingView(rootView: view.frame(width: 720, height: height)
                .background(Color(nsColor: Design.backgroundDark)))
            v.frame = NSRect(x: 0, y: 0, width: 720, height: height)
            v.layoutSubtreeIfNeeded()
            guard let r = v.bitmapImageRepForCachingDisplay(in: v.bounds),
                  let data = {
                v.cacheDisplay(in: v.bounds, to: r)
                return r.representation(using: .png, properties: [:])
            }() else {
                XCTFail("\(name) 渲染失败")
                continue
            }
            try data.write(to: URL(fileURLWithPath: "/tmp/insights-page-\(name).png"))
            rendered += 1
        }
        XCTAssertEqual(rendered, 7)
        store.close()
    }
}
