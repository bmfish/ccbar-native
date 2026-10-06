import XCTest
import SwiftUI
@testable import CCBar

/// 洞察中心五页离屏渲染冒烟测试：
/// 用真实库副本喂 VM（无副本则跳过），ImageRenderer 出 PNG 到 /tmp/insights-page-*.png
@MainActor
final class InsightsRenderTests: XCTestCase {

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

        let pages: [(String, AnyView)] = [
            ("cost", AnyView(CostPage(vm: vm))),
            ("insights", AnyView(InsightsPageView(vm: vm))),
            ("share", AnyView(SharePage(vm: vm))),
            ("channels", AnyView(ChannelsPage(vm: vm))),
            ("timeline", AnyView(TimelinePage(vm: vm))),
        ]
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
        for (name, view) in pages {
            let v = NSHostingView(rootView: view.frame(width: 720, height: 500)
                .background(Color(nsColor: Design.backgroundDark)))
            v.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
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
