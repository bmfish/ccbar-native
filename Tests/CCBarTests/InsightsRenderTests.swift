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
        let card = UsageShareCard(
            title: L("AI 用量周报"), dateText: "9月28日 ~ 10月4日",
            bigLabel: L("周消耗"), bigValue: "1.23亿",
            trend: (0..<7).map { ChartEntry(label: "09-\($0)", value: Int64($0 + 1) * 100) },
            stats: [(L("日均"), "0.2亿"), (L("峰值"), "0.5亿"), (L("累计"), "1.23亿")])
        let png = ShareCardRenderer.pngData(card, width: 460)
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png?.count ?? 0, 5000, "渲染出的 PNG 太小，疑似黑图/空白")
        try png?.write(to: URL(fileURLWithPath: "/tmp/insights-page-weekly.png"))   // 本地目检用

        // 非周一直接跳过
        let store = StatsStore(storePath: NSTemporaryDirectory() + "ccbar-weekly-\(UUID().uuidString).db")
        defer { store.close() }
        store.rebuild(configs: [])   // init 只记路径，rebuild 才开库
        let wednesday = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07（周三）
        XCTAssertNil(WeeklyReport.generateIfNeeded(store: store, now: wednesday))

        // 周一 + 空库：无数据不产图，但记账幂等（第二次直接跳过）
        let monday = Date(timeIntervalSince1970: 1_791_187_200)      // 2026-10-05（周一）
        XCTAssertNil(WeeklyReport.generateIfNeeded(store: store, now: monday))
        XCTAssertNil(WeeklyReport.generateIfNeeded(store: store, now: monday))
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

        let pages: [(String, AnyView, CGFloat)] = [
            ("cost", AnyView(CostPage(vm: vm)), 500),
            ("insights", AnyView(InsightsPageView(vm: vm)), 1350),
            ("share", AnyView(SharePage(vm: vm)), 500),
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
