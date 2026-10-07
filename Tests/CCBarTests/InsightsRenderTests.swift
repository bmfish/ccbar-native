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

        // 空库：任何一天都没有可写的数据 → nil
        let store = StatsStore(storePath: NSTemporaryDirectory() + "ccbar-weekly-\(UUID().uuidString).db")
        defer { store.close() }
        store.rebuild(configs: [])   // init 只记路径，rebuild 才开库

        // 窗口口径：周一生成上周一~周日（7..1），周二预览上一个完整周（8..2）
        let monWindow = WeeklyReport.lastWeekWindow(now: Date(timeIntervalSince1970: 1_791_187_200))
        XCTAssertEqual(monWindow.from, 7)
        XCTAssertEqual(monWindow.to, 1)
        let tueWindow = WeeklyReport.lastWeekWindow(now: Date(timeIntervalSince1970: 1_791_273_600))   // 2026-10-06（周二）
        XCTAssertEqual(tueWindow.from, 8)
        XCTAssertEqual(tueWindow.to, 2)
        // 无数据不产文件（有数据时改天会重试补账，空库永远 nil）
        let wednesday = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07（周三）
        XCTAssertNil(WeeklyReport.generateIfNeeded(store: store, now: wednesday))

        // 周一 + 空库：同样无可写数据
        let monday = Date(timeIntervalSince1970: 1_791_187_200)      // 2026-10-05（周一）
        XCTAssertNil(WeeklyReport.generateIfNeeded(store: store, now: monday))
    }

    func testWeeklyBackfillIdempotent() throws {
        let dbPath = "/tmp/ccbar-recheck/ccbar.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("无真实库副本，本地验证用")
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory() + "weekly-out-\(UUID().uuidString)")
        WeeklyReport.directoryOverride = out
        defer {
            WeeklyReport.directoryOverride = nil
            try? FileManager.default.removeItem(at: out)
        }
        let store = StatsStore(storePath: dbPath)
        defer { store.close() }
        let cc = CCSwitchAdapter(), zc = ZCodeAdapter()
        store.rebuild(configs: [
            SourceConfig(id: cc.id, enabled: true, dbPath: cc.defaultPath),
            SourceConfig(id: zc.id, enabled: true, dbPath: zc.defaultPath),
        ])
        store.syncIfNeeded()

        // 周二也能补生成上周周报（周一错过不丢）
        let tuesday = Date(timeIntervalSince1970: 1_791_273_600)   // 2026-10-06（周二）
        let path1 = WeeklyReport.generateIfNeeded(store: store, now: tuesday)
        XCTAssertNotNil(path1)
        XCTAssertEqual(path1, out.appendingPathComponent("ccbar-weekly-2026-10-05.png").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path1!))

        // 同一个报告周内换一天触发（周四）：文件已存在 → 幂等跳过
        let thursday = tuesday.addingTimeInterval(2 * 86_400)
        XCTAssertNil(WeeklyReport.generateIfNeeded(store: store, now: thursday))
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
                      token: Int64(h - 8) * 800_000)
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

    func testTimelineGrouping() throws {
        // 复刻线上串组场景：20/19/12/11 点的行混杂的 DESC 序列
        let cal = Calendar.current
        let base = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        func at(_ h: Int, _ m: Int, _ s: Int) -> Int { base + h * 3600 + m * 60 + s }
        let rows: [(time: Int, model: String, source: String, token: Int64, cost: Double)] = [
            (at(20, 26, 50), "GLM", "zcode", 0, 0),
            (at(19, 42, 10), "GLM", "zcode", 520_000, 0),
            (at(19, 41, 23), "GLM", "zcode", 520_000, 0),
            (at(12, 57, 54), "GLM", "zcode", 460_000, 0),
            (at(12, 39, 26), "GLM", "zcode", 450_000, 0),
            (at(11, 42, 38), "GLM", "zcode", 420_000, 0),
            (at(11, 40, 0), "GLM", "zcode", 420_000, 0),
        ]
        let lines = TimelinePage.buildLines(rows)

        // 组头恰好 4 个：20/19/12/11，各在组首行前，计数正确
        let headers = lines.compactMap { line -> (Int, Int)? in
            if case .header(let h, let c) = line { return (h, c) }
            return nil
        }
        XCTAssertEqual(headers.map(\.0), [20, 19, 12, 11])
        XCTAssertEqual(headers.map(\.1), [1, 2, 2, 2])

        // 数据行顺序保持 DESC、总数一致
        let dataRows = lines.compactMap { line -> Int? in
            if case .row(let time, _, _, _, _) = line { return time }
            return nil
        }
        XCTAssertEqual(dataRows, rows.map(\.time), "顺序必须保持 DESC 且不串行")

        // 每行紧随其组头之后
        for (i, line) in lines.enumerated() {
            if case .row(let time, _, _, _, _) = line {
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(time)))
                if case .header(let hh, _)? = i > 0 ? lines[i - 1] : nil {
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
        ]
        _ = pages.count
        // 整个根视图（含深色底）包一起渲染
        let root = InsightsRootView(vm: vm).frame(width: 720, height: 500)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("拿不到位图上下文")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/insights-page-cost.png"))

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
        XCTAssertEqual(rendered, 5)
        store.close()
    }
}
