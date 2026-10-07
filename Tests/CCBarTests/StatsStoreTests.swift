import XCTest
import SQLite3
@testable import CCBar

// MARK: - StatsStore 集成测试（临时目录 + 模拟 cc-switch 源库）

final class StatsStoreTests: XCTestCase {
    var tmpDir: String!
    var store: StatsStore!
    var sourcePath: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "ccbar-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        sourcePath = tmpDir + "/fixture.db"
        store = StatsStore(storePath: tmpDir + "/ccbar.db")
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    /// 模拟 cc-switch 源库：明细表 + 聚合表（聚合留空，保证 rollups 同步语句可执行）
    private func makeFixtureSource() {
        fixtureExec("""
        CREATE TABLE proxy_request_logs (
            request_id TEXT PRIMARY KEY, app_type TEXT, model TEXT,
            input_tokens INTEGER, output_tokens INTEGER,
            cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
            total_cost_usd REAL, created_at INTEGER
        );
        CREATE TABLE usage_daily_rollups (
            date TEXT, provider_id TEXT, model TEXT, request_model TEXT,
            pricing_model TEXT, app_type TEXT, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER,
            cache_creation_tokens INTEGER, total_cost_usd REAL, request_count INTEGER
        );
        """)
    }

    private func fixtureExec(_ sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            XCTFail("打不开 fixture 源库")
            return
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    private func insertFixtureRow(id: String, createdAt: Int64,
                                  input: Int64, output: Int64,
                                  cacheRead: Int64 = 0, cacheCreate: Int64 = 0,
                                  model: String = "test-model") -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO proxy_request_logs
            (request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, total_cost_usd, created_at)
        VALUES (?, 'claude', ?, ?, ?, ?, ?, 0.5, ?)
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, model, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, input)
        sqlite3_bind_int64(stmt, 4, output)
        sqlite3_bind_int64(stmt, 5, cacheRead)
        sqlite3_bind_int64(stmt, 6, cacheCreate)
        sqlite3_bind_int64(stmt, 7, createdAt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func rebuildWithFixture(enabled: Bool = true) {
        store.rebuild(configs: [SourceConfig(id: "ccswitch", enabled: enabled, dbPath: sourcePath)])
    }

    func testAttachAndBackfillAndLiveToday() throws {
        let midnight = StatsStore.localMidnight(0)
        makeFixtureSource()
        // 昨天 + 3 天前的历史行（应被懒惰补账收进 usage_log）
        XCTAssertTrue(insertFixtureRow(id: "req-B", createdAt: StatsStore.localMidnight(1) + 3600,
                                       input: 1000, output: 2000, cacheRead: 500, cacheCreate: 100))
        XCTAssertTrue(insertFixtureRow(id: "req-C", createdAt: StatsStore.localMidnight(3) + 3600,
                                       input: 10000, output: 20000))

        rebuildWithFixture()
        XCTAssertEqual(store.sourceStatus["ccswitch"], "已连接")
        XCTAssertEqual(store.attachedAdapters.count, 1)

        // 首次同步：全量回填昨天及更早
        store.syncIfNeeded()
        XCTAssertEqual(store.queryDayStats(days: 1)?.total, 3600)
        XCTAssertEqual(store.queryDayStats(days: 3)?.total, 33600, "近3天含昨天+3天前")
        XCTAssertEqual(store.queryDayStats(days: 7)?.total, 33600)

        // 今日还没数据（今日走实时视图，不同步进自建库）
        XCTAssertEqual(store.queryDayStats(days: 0)?.total, 0)

        // 源库出现今日新行 → 实时可见，且再次同步不会把它搬进 usage_log
        let aEpoch = max(midnight + 60, Int64(Date().timeIntervalSince1970) - 1800)
        XCTAssertTrue(insertFixtureRow(id: "req-A", createdAt: aEpoch,
                                       input: 100, output: 200, cacheRead: 50, cacheCreate: 10))
        store.syncIfNeeded()
        XCTAssertEqual(store.queryDayStats(days: 0)?.total, 360)
        XCTAssertEqual(store.queryDayStats(days: 0)?.reqs, 1)
        XCTAssertEqual(store.queryDayStats(days: 1)?.total, 3600, "再次同步不重复入账")

        // 汇总 = 今日实时 + 自建历史
        XCTAssertEqual(store.queryTotalStats()?.total, 33960)
        XCTAssertEqual(store.queryTotalStats()?.reqs, 3)

        // 模型分布（今日）
        let models = store.queryModelBreakdown()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "test-model")
        XCTAssertEqual(models.first?.total, 360)

        // 数据源分账（今日）
        XCTAssertEqual(store.querySourceBreakdown().first?.source, "cc-switch")
        XCTAssertEqual(store.querySourceBreakdown().first?.total, 360)

        // 工时 = 今日最早请求距现在
        let hours = store.queryWorkHours()
        XCTAssertNotNil(hours)
        XCTAssertGreaterThanOrEqual(hours!, 0)
        XCTAssertLessThan(hours!, 24)

        // 按月汇总（历史部分；今天实时由窗口层叠加，这里不含）
        let monthly = store.queryMonthlyTotals()
        XCTAssertFalse(monthly.isEmpty)
        let monthlyToken = monthly.reduce(Int64(0)) { $0 + $1.token }
        XCTAssertEqual(monthlyToken, 33600, "历史聚合表合计 = 昨天B + 3天前C")
        let monthlyReqs = monthly.reduce(0) { $0 + $1.reqs }
        XCTAssertEqual(monthlyReqs, 2)
    }

    func testExportImportIdempotent() throws {
        // 夹具：昨天 3600 + 3 天前 30000
        makeFixtureSource()
        XCTAssertTrue(insertFixtureRow(id: "req-B", createdAt: StatsStore.localMidnight(1) + 3600,
                                       input: 1000, output: 2000, cacheRead: 500, cacheCreate: 100))
        XCTAssertTrue(insertFixtureRow(id: "req-C", createdAt: StatsStore.localMidnight(3) + 3600,
                                       input: 10000, output: 20000))
        rebuildWithFixture()
        store.syncIfNeeded()

        let path = tmpDir + "/export.csv"
        XCTAssertTrue(store.exportCSV(to: path))

        // 导入到新库（挂同一源但不重新同步，隔离出纯导入路径）
        let imported = StatsStore(storePath: tmpDir + "/imported.db")
        defer { imported.close() }
        imported.rebuild(configs: [SourceConfig(id: "ccswitch", enabled: true, dbPath: sourcePath)])
        let r1 = imported.importCSV(from: path)
        XCTAssertEqual(r1.read, 2)
        XCTAssertEqual(r1.inserted, 2)
        XCTAssertEqual(r1.skipped, 0)
        XCTAssertEqual(imported.queryTotalStats()?.total, 33600)
        XCTAssertEqual(imported.queryDayStats(days: 7)?.total, 33600, "导入后 daily_agg 已按窗口重建")

        // 再导一遍：幂等——零新增，全部按主键跳过
        let r2 = imported.importCSV(from: path)
        XCTAssertEqual(r2.read, 2)
        XCTAssertEqual(r2.inserted, 0, "重复导入不得新增（幂等）")
        XCTAssertEqual(r2.skipped, 2)
        XCTAssertEqual(imported.queryTotalStats()?.total, 33600, "幂等导入后总量不变")

        // 非法行跳过：追加一条残缺记录
        let handle = FileHandle(forUpdatingAtPath: path)!
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("bad-source,broken-id,,model,x,y,z\n".utf8))
        try handle.close()
        let r3 = imported.importCSV(from: path)
        XCTAssertEqual(r3.read, 2, "两条合法行仍计入读取")
        XCTAssertEqual(r3.inserted, 0)
        XCTAssertEqual(r3.skipped, 3, "1 条非法 + 2 条重复")
    }

    func testInsightQueries() throws {
        // 夹具：昨天 3600（$0.5）+ 3 天前 30000（$0.5）+ 今日实时 360（$0.5）
        let midnight = StatsStore.localMidnight(0)
        makeFixtureSource()
        XCTAssertTrue(insertFixtureRow(id: "req-B", createdAt: StatsStore.localMidnight(1) + 3600,
                                       input: 1000, output: 2000, cacheRead: 500, cacheCreate: 100))
        XCTAssertTrue(insertFixtureRow(id: "req-C", createdAt: StatsStore.localMidnight(3) + 3600,
                                       input: 10000, output: 20000))
        rebuildWithFixture()
        store.syncIfNeeded()
        let aEpoch = max(midnight + 60, Int64(Date().timeIntervalSince1970) - 1800)
        XCTAssertTrue(insertFixtureRow(id: "req-A", createdAt: aEpoch,
                                       input: 100, output: 200, cacheRead: 50, cacheCreate: 10))
        store.syncIfNeeded()

        // 费用（每行 0.5，共 3 行）
        XCTAssertEqual(store.queryCost(days: 30), 1.5, accuracy: 0.0001)
        XCTAssertEqual(store.queryCost(days: 0), 0.5, accuracy: 0.0001)
        let byModel = store.queryCostByModel(days: 30)
        XCTAssertEqual(byModel.count, 1)
        XCTAssertEqual(byModel.first?.cost ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(byModel.first?.token, 33960)

        // 费用曲线：三个有数据的日期
        let daily = store.queryCostDaily(days: 30)
        XCTAssertEqual(daily.count, 3)
        XCTAssertEqual(daily.reduce(0.0) { $0 + $1.cost }, 1.5, accuracy: 0.0001)

        // 连续天数：daily_agg 只有昨天与 3 天前（中间断档）→ 从昨天数 1 天
        XCTAssertEqual(store.queryStreak(), 1)

        // 周环比：本周（含今天）= 昨天 + 3天前 + 今日；上周为 0
        let delta = store.queryWeeklyDelta()
        XCTAssertEqual(delta.thisWeek, 33960)
        XCTAssertEqual(delta.lastWeek, 0)

        // 峰值日 = 3 天前 30000
        let peak = store.queryPeakDay(days: 30)
        XCTAssertEqual(peak?.token, 30000)
        XCTAssertEqual(peak?.date, StatsStore.dayString(fromEpoch: StatsStore.localMidnight(3)))

        // 时段分布总量守恒
        let hist = store.queryHourHistogram(days: 30)
        XCTAssertEqual(hist.values.reduce(0, +), 33960)

        // 渠道每日：2 个历史日 + 今日实时 1 行
        let channels = store.queryChannelDaily(days: 30)
        XCTAssertEqual(channels.count, 3)
        XCTAssertTrue(channels.allSatisfy { $0.source == "cc-switch" })

        // 今日流水：1 条
        let timeline = store.queryTodayTimeline()
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline.first?.token, 360)
        XCTAssertEqual(timeline.first?.cost ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(timeline.first?.model, "test-model")

        // 每日 token：2 个历史日 + 今日
        XCTAssertEqual(store.queryDailyTokens(days: 30).count, 3)

        // 应用每日（app_type='claude'）：2 个历史日 + 今日
        let apps = store.queryAppDaily(days: 30)
        XCTAssertEqual(apps.count, 3)
        XCTAssertTrue(apps.allSatisfy { $0.app == "claude" })

        // 构成每日：昨天 input=1000 output=2000 缓存读=500 缓存创建=100
        let comp = store.queryCompositionDaily(days: 30)
        XCTAssertEqual(comp.count, 3)
        let yst = comp.first { $0.date == StatsStore.dayString(fromEpoch: StatsStore.localMidnight(1)) }
        XCTAssertEqual(yst?.input, 1000)
        XCTAssertEqual(yst?.output, 2000)
        XCTAssertEqual(yst?.cacheRead, 500)
        XCTAssertEqual(yst?.cacheCreate, 100)

        // 月度进度：mtd 至少含今日实时，天数口径合法
        let mp = store.queryMonthProgress()
        XCTAssertGreaterThanOrEqual(mp.mtd, 360)
        XCTAssertGreaterThanOrEqual(mp.daysElapsed, 1)
        XCTAssertTrue((28...31).contains(mp.daysInMonth))

        // 近 30 天使用量最大的模型
        let top = store.queryTopModel(days: 30)
        XCTAssertEqual(top?.model, "test-model")
        XCTAssertEqual(top?.token, 33960)

        // 任意日期流水：昨天的历史行（今日实时行不混入）
        let yesterday = Date(timeIntervalSince1970: TimeInterval(StatsStore.localMidnight(1)))
        let yTimeline = store.queryTimeline(day: yesterday)
        XCTAssertEqual(yTimeline.count, 1)
        XCTAssertEqual(yTimeline.first?.token, 3600)
        XCTAssertEqual(yTimeline.first?.model, "test-model")
        XCTAssertEqual(yTimeline.first?.cost ?? 0, 0.5, accuracy: 0.0001)
        // 今日流水走实时视图
        XCTAssertEqual(store.queryTimeline(day: Date()).count, 1)

        // 本月费用 MTD：至少含今日实时的 $0.5；天数口径合法
        let mtd = store.queryCostMTD()
        XCTAssertGreaterThanOrEqual(mtd.mtd, 0.5)
        XCTAssertGreaterThanOrEqual(mtd.daysElapsed, 1)
        XCTAssertTrue((28...31).contains(mtd.daysInMonth))
    }

    func testModelHistoryAndWindowStats() throws {
        // 5 天前 model-B 首用、3 天前 model-A 加入、昨天 model-A 再用
        makeFixtureSource()
        XCTAssertTrue(insertFixtureRow(id: "req-old", createdAt: StatsStore.localMidnight(5) + 3600,
                                       input: 1000, output: 1000, model: "model-B"))
        XCTAssertTrue(insertFixtureRow(id: "req-mid", createdAt: StatsStore.localMidnight(3) + 3600,
                                       input: 100, output: 200, model: "model-A"))
        XCTAssertTrue(insertFixtureRow(id: "req-new", createdAt: StatsStore.localMidnight(1) + 3600,
                                       input: 10000, output: 20000, model: "model-A"))
        rebuildWithFixture()
        store.syncIfNeeded()

        // 编年史按首用时间升序：model-B（5 天前）→ model-A（3 天前）
        let history = store.queryModelHistory()
        XCTAssertEqual(history.map(\.model), ["model-B", "model-A"])
        XCTAssertEqual(history[0].firstEpoch, StatsStore.localMidnight(5) + 3600)
        XCTAssertEqual(history[0].lastEpoch, StatsStore.localMidnight(5) + 3600)
        XCTAssertEqual(history[0].token, 2000)
        XCTAssertEqual(history[1].firstEpoch, StatsStore.localMidnight(3) + 3600)
        XCTAssertEqual(history[1].lastEpoch, StatsStore.localMidnight(1) + 3600)
        XCTAssertEqual(history[1].token, 30300)

        // 任意窗口统计：近 3 天（含昨天）= model-A 两行 30300
        XCTAssertEqual(store.queryWindowStats(daysAgoFrom: 3, daysAgoTo: 1)?.total, 30300)
        XCTAssertEqual(store.queryWindowStats(daysAgoFrom: 3, daysAgoTo: 1)?.reqs, 2)
        // 窗口外（5 天前）不计入
        XCTAssertEqual(store.queryWindowStats(daysAgoFrom: 6, daysAgoTo: 4)?.total, 2000)

        // 窗口日序列：日期升序、只含窗口内有数据的日期
        let daily = store.queryDailyTokensBetween(daysAgoFrom: 5, daysAgoTo: 1)
        XCTAssertEqual(daily.map(\.date), [
            StatsStore.dayString(fromEpoch: StatsStore.localMidnight(5)),
            StatsStore.dayString(fromEpoch: StatsStore.localMidnight(3)),
            StatsStore.dayString(fromEpoch: StatsStore.localMidnight(1)),
        ])
        XCTAssertEqual(daily.map(\.token), [2000, 300, 30000])
    }

    func testSyncIdempotentAcrossRepeats() throws {
        makeFixtureSource()
        XCTAssertTrue(insertFixtureRow(id: "req-B", createdAt: StatsStore.localMidnight(1) + 3600,
                                       input: 1000, output: 2000))
        rebuildWithFixture()
        store.syncIfNeeded()
        let first = store.queryDayStats(days: 7)?.total
        for _ in 0..<3 { store.syncIfNeeded() }
        XCTAssertEqual(store.queryDayStats(days: 7)?.total, first, "重复同步幂等")

        // 再次 rebuild：daily_agg 回填标记已存在，历史不重复累计
        store.rebuild(configs: [SourceConfig(id: "ccswitch", enabled: true, dbPath: sourcePath)])
        store.syncIfNeeded()
        XCTAssertEqual(store.queryTotalStats()?.total, first, "重建连接后聚合不重复")
    }

    func testAttachDiagnostics() {
        // 文件不存在
        store.rebuild(configs: [SourceConfig(id: "ccswitch", enabled: true,
                                             dbPath: tmpDir + "/no-such-file.db")])
        XCTAssertEqual(store.sourceStatus["ccswitch"], "文件不存在")
        XCTAssertTrue(store.attachedAdapters.isEmpty)
        XCTAssertNil(store.queryDayStats(days: 0), "没有可用数据源时不出数")

        // 文件在但缺必需表
        fixtureExec("CREATE TABLE something_else (id INTEGER);")
        store.rebuild(configs: [SourceConfig(id: "ccswitch", enabled: true, dbPath: sourcePath)])
        XCTAssertEqual(store.sourceStatus["ccswitch"], "缺少必需表")

        // 未启用
        store.rebuild(configs: [SourceConfig(id: "ccswitch", enabled: false, dbPath: sourcePath)])
        XCTAssertEqual(store.sourceStatus["ccswitch"], "未启用")

        // 未知数据源 id：忽略
        store.rebuild(configs: [SourceConfig(id: "unknown", enabled: true, dbPath: sourcePath)])
        XCTAssertNil(store.sourceStatus["unknown"])
    }
}

// MARK: - DataCache

final class DataCacheTests: XCTestCase {
    override func setUp() {
        DataCache.shared.resetForTesting()
    }

    func testUpdateAndRead() {
        let today = DayStats(reqs: 1, input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
        DataCache.shared.update(today: today, yesterday: nil, week: nil, month: nil,
                                total: TotalStats(reqs: 9, total: 99), models: nil, workHours: 1.5)
        XCTAssertEqual(DataCache.shared.getCachedToday(), today)
        XCTAssertEqual(DataCache.shared.getCachedTotal()?.total, 99)
        XCTAssertEqual(DataCache.shared.getCachedWorkHours(), 1.5)
        XCTAssertNil(DataCache.shared.getCachedYesterday())
    }

    func testNilDoesNotOverwrite() {
        let today = DayStats(reqs: 1, input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
        DataCache.shared.update(today: today, yesterday: nil, week: nil, month: nil,
                                total: nil, models: [ModelStat(model: "m", input: 1, output: 1, total: 2)],
                                workHours: nil)
        // 第二次更新没带的字段不被清空
        DataCache.shared.update(today: today, yesterday: nil, week: nil, month: nil,
                                total: nil, models: nil, workHours: nil)
        XCTAssertEqual(DataCache.shared.getCachedModelBreakdown()?.first?.model, "m")
        XCTAssertEqual(DataCache.shared.getCachedToday(), today)
    }

    func testCacheIntervals() {
        XCTAssertTrue(DataCache.shared.needsDailyCache())
        XCTAssertTrue(DataCache.shared.needsModelCache())
        DataCache.shared.markDailyCacheDone()
        DataCache.shared.markModelCacheDone()
        XCTAssertFalse(DataCache.shared.needsDailyCache())
        XCTAssertFalse(DataCache.shared.needsModelCache())
    }
}
