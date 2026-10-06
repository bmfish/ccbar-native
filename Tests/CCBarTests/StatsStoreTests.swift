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
                                  cacheRead: Int64 = 0, cacheCreate: Int64 = 0) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO proxy_request_logs
            (request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, total_cost_usd, created_at)
        VALUES (?, 'claude', 'test-model', ?, ?, ?, ?, 0.5, ?)
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, input)
        sqlite3_bind_int64(stmt, 3, output)
        sqlite3_bind_int64(stmt, 4, cacheRead)
        sqlite3_bind_int64(stmt, 5, cacheCreate)
        sqlite3_bind_int64(stmt, 6, createdAt)
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
