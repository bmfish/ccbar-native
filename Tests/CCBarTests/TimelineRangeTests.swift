import XCTest
@testable import CCBar

/// 流水页区间模式：每日按小时聚合、7/30/全部按日维度，口径与 daily_agg/usage_all 一致
@MainActor
final class TimelineRangeTests: XCTestCase {

    private var tmpDir: String!
    private var store: StatsStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = NSTemporaryDirectory() + "ccbar-timeline-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        store = StatsStore(storePath: tmpDir + "/ccbar.db")
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "")])
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpDir)
        try super.tearDownWithError()
    }

    /// 造两天数据：今天两笔（01:00 = 2.5，02:00 = 1.0）、昨天 01:00 = 1.5
    private func seed() {
        store.upsertTraeRows([
            TraeRow(sessionID: "t1", model: "m", input: 100, output: 50, cacheRead: 0, cacheWrite: 0,
                    costUsd: 0, credits: 2.5, epoch: StatsStore.localMidnight(0) + 3_600),
            TraeRow(sessionID: "t2", model: "m", input: 20, output: 10, cacheRead: 0, cacheWrite: 0,
                    costUsd: 0, credits: 1.0, epoch: StatsStore.localMidnight(0) + 7_200),
            TraeRow(sessionID: "y1", model: "m", input: 10, output: 5, cacheRead: 0, cacheWrite: 0,
                    costUsd: 0, credits: 1.5, epoch: StatsStore.localMidnight(1) + 3_600),
        ])
        store.refreshDailyAgg(fromEpoch: StatsStore.localMidnight(3), toEpoch: StatsStore.localMidnight(0))
    }

    /// 单日预设（手动翻日）按小时聚合，同时加载逐笔供点开小时用
    func testSingleDayPresetAggregatesByHour() {
        seed()
        let vm = InsightsViewModel()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        vm.applyTimelinePreset(.custom, day: yesterday, store: store)

        XCTAssertEqual(vm.timelinePreset, .custom)
        XCTAssertTrue(vm.timelinePreset.isSingleDay, "单日视图")
        // 昨日只有 01:00 一笔
        XCTAssertEqual(vm.timelineHourly.count, 1)
        XCTAssertEqual(vm.timelineHourly.first?.hour, 1)
        XCTAssertEqual(vm.timelineHourly.first?.reqs, 1)
        XCTAssertEqual(vm.timelineHourly.first?.credits ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(vm.timelineHourly.first?.token, 15)
        // 逐笔明细随单日一起加载（点击小时才展示），默认全部折叠
        XCTAssertEqual(vm.timeline.count, 1)
        XCTAssertTrue(vm.timelineExpandedHours.isEmpty)
        XCTAssertTrue(vm.timelineDaily.isEmpty)
    }

    func testTodayPresetKeepsPerSessionRows() {
        seed()
        let vm = InsightsViewModel()
        vm.applyTimelinePreset(.today, store: store)

        XCTAssertEqual(vm.timelinePreset, .today)
        XCTAssertEqual(vm.timeline.count, 2, "今日保留逐笔会话行")
        // 今日小时聚合同时可用（1 点、2 点各一笔）
        XCTAssertEqual(vm.timelineHourly.map(\.hour), [1, 2])
        XCTAssertEqual(vm.timelineHourly.reduce(0) { $0 + $1.credits }, 3.5, accuracy: 1e-9)
        // 小时默认全折叠，点击展开/收起
        XCTAssertTrue(vm.timelineExpandedHours.isEmpty)
        vm.toggleTimelineHour(1)
        XCTAssertEqual(vm.timelineExpandedHours, [1])
        vm.toggleTimelineHour(1)
        XCTAssertTrue(vm.timelineExpandedHours.isEmpty)
    }

    func testD30PresetUsesDayDimension() {
        seed()
        let vm = InsightsViewModel()
        vm.applyTimelinePreset(.d30, store: store)

        XCTAssertEqual(vm.timelinePreset, .d30)
        XCTAssertFalse(vm.timelinePreset.isSingleDay, "近30天必须是按日维度")

        let dates = Set(vm.timelineDaily.map(\.date))
        XCTAssertEqual(dates.count, 2, "两天的日汇总")
        let today = StatsStore.dayString(fromEpoch: StatsStore.localMidnight(0))
        let todayRows = vm.timelineDaily.filter { $0.date == today }
        XCTAssertEqual(todayRows.count, 1)
        XCTAssertEqual(todayRows.first?.reqs, 2)
        XCTAssertEqual(todayRows.first?.credits ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(todayRows.first?.token, 180)
        // 多日默认全折叠
        XCTAssertTrue(vm.timelineExpandedDays.isEmpty)
    }

    func testD7AndAllPresetsCoverSameDailyData() {
        seed()
        let vm7 = InsightsViewModel()
        vm7.applyTimelinePreset(.d7, store: store)
        XCTAssertEqual(vm7.timelinePreset, .d7)
        XCTAssertEqual(Set(vm7.timelineDaily.map(\.date)).count, 2)

        let vmAll = InsightsViewModel()
        vmAll.applyTimelinePreset(.all, store: store)
        XCTAssertEqual(vmAll.timelinePreset, .all)
        XCTAssertEqual(Set(vmAll.timelineDaily.map(\.date)).count, 2)
        XCTAssertEqual(vmAll.timelineDaily.reduce(0) { $0 + $1.credits },
                       vm7.timelineDaily.reduce(0) { $0 + $1.credits }, accuracy: 1e-9)
    }

    func testToggleDayLoadsDetailLazily() {
        seed()
        let vm = InsightsViewModel()
        vm.applyTimelinePreset(.d7, store: store)
        let yesterday = StatsStore.dayString(fromEpoch: StatsStore.localMidnight(1))
        XCTAssertNil(vm.timelineDayDetails[yesterday], "未展开前不查明细")

        vm.toggleTimelineDay(yesterday, store: store)
        XCTAssertTrue(vm.timelineExpandedDays.contains(yesterday))
        XCTAssertEqual(vm.timelineDayDetails[yesterday]?.count, 1, "展开后懒加载该日逐笔")

        vm.toggleTimelineDay(yesterday, store: store)
        XCTAssertFalse(vm.timelineExpandedDays.contains(yesterday), "再次点击收起")
    }
}
