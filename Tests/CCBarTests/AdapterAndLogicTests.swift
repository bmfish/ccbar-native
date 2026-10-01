import XCTest
@testable import CCBar

// MARK: - 适配器 SQL 生成

final class AdapterSQLTests: XCTestCase {
    let cc = CCSwitchAdapter()
    let zc = ZCodeAdapter()

    func testCCSwitchAttachSQL() {
        let sql = cc.attachSQL(fileURL: "/tmp/x.db")
        XCTAssertTrue(sql.contains("file:/tmp/x.db?mode=ro"), "源库必须只读 ATTACH")
        XCTAssertTrue(sql.contains("AS \(cc.alias)"))
    }

    func testCCSwitchSyncSQLs() {
        let sqls = cc.syncSQLs(alias: "src_cc", fromEpoch: 1000, todayEpoch: 2000)
        XCTAssertEqual(sqls.count, 2, "明细 + 历史聚合两条")
        XCTAssertTrue(sqls[0].contains("INSERT OR IGNORE INTO usage_log"), "幂等写入")
        XCTAssertTrue(sqls[0].contains("FROM src_cc.proxy_request_logs"))
        XCTAssertTrue(sqls[0].contains("created_at >= 1000 AND created_at < 2000"), "epoch 区间条件")
        XCTAssertTrue(sqls[1].contains("usage_daily_rollups"))
        XCTAssertTrue(sqls[1].contains("INSERT OR IGNORE INTO usage_log"))
    }

    func testZCodeSyncSQLUsesMilliseconds() {
        let sqls = zc.syncSQLs(alias: "src_zc", fromEpoch: 1000, todayEpoch: 2000)
        XCTAssertEqual(sqls.count, 1)
        XCTAssertTrue(sqls[0].contains("started_at >= 1000 * 1000 AND started_at < 2000 * 1000"),
                      "ZCode 的时间戳是毫秒")
        XCTAssertTrue(sqls[0].contains("status != 'running'"), "运行中的请求不入账")
    }

    func testTodayFragmentsUseBakedEpoch() {
        // 边界必须是构建时烘进去的整数 epoch；严禁 SQL 侧时区运算
        // （strftime 的 localtime + %s 组合会偏移一个时区）
        let ccFrag = cc.todayFragment(alias: "a", todayStartEpoch: 1790784000)
        XCTAssertTrue(ccFrag.contains("created_at >= 1790784000"))
        XCTAssertFalse(ccFrag.contains("strftime"), "视图边界不得依赖 SQL 时区函数")

        let zcFrag = zc.todayFragment(alias: "a", todayStartEpoch: 1790784000)
        XCTAssertTrue(zcFrag.contains("started_at >= 1790784000 * 1000"))
        XCTAssertTrue(zcFrag.contains("status != 'running'"))
        XCTAssertFalse(zcFrag.contains("strftime"))
    }

    func testRegistry() {
        XCTAssertEqual(SourceRegistry.adapters.count, 2)
        XCTAssertNotNil(SourceRegistry.adapter(for: "ccswitch"))
        XCTAssertNil(SourceRegistry.adapter(for: "nope"))
    }
}

// MARK: - 纯类型与工具

final class ModelLogicTests: XCTestCase {
    func testDayStatsTotal() {
        let s = DayStats(reqs: 3, input: 100, output: 200, cacheCreate: 10, cacheRead: 50)
        XCTAssertEqual(s.total, 360, "口径：input + output + 缓存创建 + 缓存读")
    }

    func testLocalMidnight() {
        let cal = Calendar.current
        let now = Date()
        XCTAssertEqual(StatsStore.localMidnight(0, now: now),
                       Int64(cal.startOfDay(for: now).timeIntervalSince1970))
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: now)!
        XCTAssertEqual(StatsStore.localMidnight(2, now: now),
                       Int64(cal.startOfDay(for: twoDaysAgo).timeIntervalSince1970))
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(StatsStore.localMidnight(-1, now: now),
                       Int64(cal.startOfDay(for: tomorrow).timeIntervalSince1970),
                       "daysAgo=-1 应为明天 0 点（今日区间的上界）")
    }

    func testFormatTokens() {
        XCTAssertEqual(Design.formatTokens(9999), "9999")
        XCTAssertEqual(Design.formatTokens(10_000), "1万")
        XCTAssertEqual(Design.formatTokens(123_456), "12万")
        XCTAssertEqual(Design.formatTokens(150_000_000), "1.50亿")
        XCTAssertEqual(Design.formatTokensK(10_000), "1万")
    }
}
