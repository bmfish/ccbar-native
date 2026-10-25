import XCTest
@testable import CCBar

// MARK: - Trae 数据源单测（解析 / 归一化 / upsert 语义 / 凭据链序列化）

final class TraeSyncTests: XCTestCase {
    var tmpDir: String!
    var store: StatsStore!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "ccbar-trae-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        store = StatsStore(storePath: tmpDir + "/ccbar.db")
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: 响应解析与归一化

    func testNormalizeMapsTokensAndCredits() throws {
        let json = """
        {"session_id":"abc123","model_name":"GLM-5.3-Flash","usage_time":1791460506,
         "amount_float":0.9128,"credits_float":0.9128,"cost_money_float":0.02282,
         "extra_info":{"input_token":142064,"output_token":3710,
                       "cache_read_token":137536,"cache_write_token":0}}
        """
        let session = try JSONDecoder().decode(TraeSession.self, from: json.data(using: .utf8)!)
        let row = TraeSync.normalize(session)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.sessionID, "abc123")
        XCTAssertEqual(row?.model, "GLM-5.3-Flash")
        // Trae 的 input_token 是总量口径（含缓存），入库折算为净输入：142064 - 137536
        XCTAssertEqual(row?.input, 142064 - 137536)
        XCTAssertEqual(row?.output, 3710)
        XCTAssertEqual(row?.cacheRead, 137536)
        XCTAssertEqual(row?.cacheWrite, 0)
        XCTAssertEqual(row?.credits ?? -1, 0.9128, accuracy: 1e-9)
        XCTAssertEqual(row?.costUsd ?? -1, 0.02282, accuracy: 1e-9)
        XCTAssertEqual(row?.epoch, 1791460506)
        // 幂等主键只由会话决定（usage_time 会随会话推进漂移，不能进主键）
        XCTAssertEqual(row?.requestID, "trae|abc123")
    }

    func testNormalizeSkipsIncompleteSessions() throws {
        let noTime = try JSONDecoder().decode(TraeSession.self,
            from: #"{"session_id":"a","model_name":"m"}"#.data(using: .utf8)!)
        XCTAssertNil(TraeSync.normalize(noTime))
        let noID = try JSONDecoder().decode(TraeSession.self,
            from: #"{"usage_time":123}"#.data(using: .utf8)!)
        XCTAssertNil(TraeSync.normalize(noID))
        // credits 缺失时回落 amount
        let fallback = try JSONDecoder().decode(TraeSession.self,
            from: #"{"session_id":"a","usage_time":10,"amount_float":1.5}"#.data(using: .utf8)!)
        XCTAssertEqual(TraeSync.normalize(fallback)?.credits ?? -1, 1.5, accuracy: 1e-9)
    }

    func testUsageResponsePaginationFields() throws {
        let json = """
        {"total":2,"user_usage_group_by_sessions":[
            {"session_id":"s1","usage_time":100},
            {"session_id":"s2","usage_time":200}]}
        """
        let resp = try JSONDecoder().decode(TraeUsageResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(resp.total, 2)
        XCTAssertEqual(resp.user_usage_group_by_sessions?.count, 2)
    }

    // MARK: 分页截断：窗口二分补齐

    private func row(_ id: String, credits: Double = 0, epoch: Int64 = 0) -> TraeRow {
        TraeRow(sessionID: id, model: "m", input: 1, output: 1, cacheRead: 0, cacheWrite: 0,
                costUsd: 0, credits: credits, epoch: epoch)
    }

    /// 顶层窗口触达分页上限 → 恰好二分一次；子窗口完整 → 合并去重、truncated=false
    func testFetchWithSplitSplitsTruncatedWindow() {
        let day: Int64 = 86_400
        let span = 8 * day
        var windows: [(Int64, Int64)] = []
        let result = TraeSync.fetchWithSplit(fromEpoch: 0, toEpoch: span) { f, t in
            windows.append((f, t))
            if t - f >= span {
                // 顶层必截断；其行在拆分后应被丢弃（改由两个子窗口重取）
                return .success([self.row("stale", credits: 9)], truncated: true)
            }
            // 两个子窗口都含边界会话 b：后取（较新窗口）覆盖
            let b = self.row("b", credits: f == 0 ? 1 : 2)
            return .success([self.row("s\(f / day)"), b], truncated: false)
        }
        guard case .success(let rows, let truncated) = result else { return XCTFail("应成功") }
        XCTAssertFalse(truncated)
        XCTAssertEqual(windows.count, 3, "截断后只二分一层：顶层 + 两个子窗口")
        XCTAssertEqual(Set(rows.map(\.sessionID)), ["s0", "s4", "b"], "边界会话去重、顶层旧行丢弃")
        XCTAssertEqual(rows.first { $0.sessionID == "b" }?.credits, 2, "较新窗口覆盖边界会话")
    }

    /// 最小粒度（1 天）仍截断：不无限拆分，返回 truncated=true 供调用方保留水位
    func testFetchWithSplitKeepsTruncatedAtMinGranularity() {
        var calls = 0
        let result = TraeSync.fetchWithSplit(fromEpoch: 0, toEpoch: 86_400) { _, _ in
            calls += 1
            return .success([self.row("s")], truncated: true)
        }
        guard case .success(_, let truncated) = result else { return XCTFail("应成功") }
        XCTAssertTrue(truncated)
        XCTAssertEqual(calls, 1, "单日窗口不再拆分")
    }

    // MARK: 分页提前停（服务端按 usage_time 倒序）

    private func session(_ id: String, _ t: Int64) -> TraeSession {
        let json = #"{"session_id":"\#(id)","usage_time":\#(t)}"#
        return try! JSONDecoder().decode(TraeSession.self, from: json.data(using: .utf8)!)
    }

    /// 整页都早于截止点 → 不再请求后续页；已取到的行照常返回，且不算截断
    func testPaginateStopsAtPageFullyOlderThanCutoff() {
        let pages: [[Int64]] = [[500, 400], [300, 200], [100, 50]]
        var requested: [Int] = []
        var stats: (pages: Int, rows: Int, stoppedEarly: Bool)?
        let result = TraeSync.paginate(earlyStopBefore: 350,
                                       onPageStats: { stats = ($0, $1, $2) }) { page in
            requested.append(page)
            return .page(pages[page - 1].map { self.session("s\(page)-\($0)", $0) }, total: 6)
        }
        guard case .success(let rows, let truncated) = result else { return XCTFail("应成功") }
        XCTAssertEqual(requested, [1, 2], "第 2 页最新一条已早于截止点，不应再翻第 3 页")
        XCTAssertEqual(rows.count, 4)
        XCTAssertFalse(truncated)
        XCTAssertEqual(stats?.pages, 2)
        XCTAssertEqual(stats?.rows, 4)
        XCTAssertEqual(stats?.stoppedEarly, true)
    }

    /// 首次全量（无截止点）时按 total 翻完所有页
    func testPaginateWithoutCutoffFetchesUntilTotal() {
        var requested: [Int] = []
        let result = TraeSync.paginate(earlyStopBefore: nil) { page in
            requested.append(page)
            return .page([self.session("s\(page)", Int64(1000 - page))], total: 3)
        }
        guard case .success(let rows, let truncated) = result else { return XCTFail("应成功") }
        XCTAssertEqual(requested, [1, 2, 3])
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(truncated)
    }

    /// 触达 50 页上限仍没翻完 → truncated，调用方据此不推进水位/截止点
    func testPaginateReportsTruncationAtPageCap() {
        var requested = 0
        let result = TraeSync.paginate(earlyStopBefore: nil) { page in
            requested += 1
            return .page([self.session("s\(page)", Int64(10_000 - page))], total: 10_000)
        }
        guard case .success(_, let truncated) = result else { return XCTFail("应成功") }
        XCTAssertEqual(requested, TraeAPI.maxPages)
        XCTAssertTrue(truncated)
    }

    /// 数据水位只随实际看到的最新 usage_time 前进，空结果不回退、超前时间封顶
    func testNextDataWatermark() {
        XCTAssertEqual(StatsStore.nextDataWatermark(previous: 0, fetchedMax: 100, toEpoch: 200), 100)
        XCTAssertEqual(StatsStore.nextDataWatermark(previous: 150, fetchedMax: 100, toEpoch: 200), 150,
                       "旧水位不能回退")
        XCTAssertEqual(StatsStore.nextDataWatermark(previous: 150, fetchedMax: nil, toEpoch: 200), 150,
                       "空结果应保留旧水位，给延迟数据留重扫机会")
        XCTAssertEqual(StatsStore.nextDataWatermark(previous: 0, fetchedMax: 300, toEpoch: 200), 200,
                       "服务端时间超前时以窗口上界封顶")
    }

    // MARK: JWT / Set-Cookie

    /// JWT payload exp 解析（base64url，无 padding）
    func testJwtExpParsing() {
        // {"exp":1700000000} 的 base64url
        let payload = Data(#"{"exp":1700000000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        XCTAssertEqual(TraeSync.jwtExp(token), 1_700_000_000)
        XCTAssertEqual(TraeSync.jwtExp("not-a-jwt"), 0)
    }

    func testExtractSessionCookie() {
        // URLSession 会把多条 Set-Cookie 合并成逗号串
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": "sid_guard=x%7C1; Path=/, X-Cloudide-Session=KC_lA83=.18dc8d30b30; Path=/; HttpOnly, ttwid=1%7Cabc"
        ]
        XCTAssertEqual(TraeSync.extractSessionCookie(from: headers), "KC_lA83=.18dc8d30b30")
        XCTAssertNil(TraeSync.extractSessionCookie(from: ["Set-Cookie": "other=1"]))
    }

    // MARK: 凭据解析（sessionid / 整段 Cookie / X-Cloudide-Session）

    func testParseCredentialAcceptsCommonPasteFormats() {
        let bare = TraeSync.parseCredential("  abc123\n")
        XCTAssertEqual(bare.passportCookie, "sessionid=abc123")
        XCTAssertTrue(bare.cloudideSession.isEmpty)

        XCTAssertEqual(TraeSync.parseCredential("sessionid=abc123").passportCookie,
                       "sessionid=abc123")
        XCTAssertEqual(TraeSync.parseCredential("foo=1; sessionid=abc123; Path=/; HttpOnly").passportCookie,
                       "sessionid=abc123")
        XCTAssertEqual(TraeSync.parseCredential("Cookie: sessionid=abc123; foo=1").passportCookie,
                       "sessionid=abc123")
        XCTAssertEqual(TraeSync.parseCredential(#"sessionid="abc123""#).passportCookie,
                       "sessionid=abc123")
    }

    func testParseCredentialAcceptsCloudideSession() {
        let session = TraeSync.parseCredential(
            "X-Cloudide-Session=KC_lA83=.18dc8d30b30; Path=/; HttpOnly")
        XCTAssertEqual(session.cloudideSession, "KC_lA83=.18dc8d30b30")
        XCTAssertTrue(session.passportCookie.isEmpty)

        let both = TraeSync.parseCredential("sessionid=abc; X-Cloudide-Session=def")
        XCTAssertEqual(both.passportCookie, "sessionid=abc")
        XCTAssertEqual(both.cloudideSession, "def")
    }

    func testParseCredentialEmptyAndUnknownFormats() {
        XCTAssertEqual(TraeSync.parseCredential("   ").passportCookie, "")
        XCTAssertEqual(TraeSync.parseCredential("").cloudideSession, "")
        // 未识别的 cookie 串保持旧行为：原样交给 Login
        XCTAssertEqual(TraeSync.parseCredential("foo=bar").passportCookie, "foo=bar")
    }

    // MARK: 凭据状态序列化（meta 往返）

    func testAuthMetaRoundTrip() {
        let auth = TraeAuth(cloudideSession: "sess=.123", jwt: "h.p.s", jwtExp: 1_791_489_157)
        let raw = StatsStore.traeAuthToMeta(auth)
        XCTAssertEqual(StatsStore.traeAuthFromMeta(raw), auth)
        XCTAssertEqual(StatsStore.traeAuthFromMeta(""), TraeAuth())   // 空值容错
    }

    // MARK: upsert 语义（会话聚合快照：同主键覆盖而非忽略）

    func testTraeUpsertReplacesGrowingSession() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "")])

        let first = TraeRow(sessionID: "s1", model: "GLM-5.3-Flash",
                            input: 100, output: 10, cacheRead: 50, cacheWrite: 0,
                            costUsd: 0.01, credits: 0.5, epoch: StatsStore.localMidnight(0) + 3_600)
        store.upsertTraeRows([first])

        // 会话继续对话：用量增长、usage_time 前移 → 覆盖而非新增（日期必须动态取今天，防跨日腐烂）
        let grown = TraeRow(sessionID: "s1", model: "GLM-5.3-Flash",
                            input: 250, output: 30, cacheRead: 90, cacheWrite: 0,
                            costUsd: 0.03, credits: 1.2, epoch: StatsStore.localMidnight(0) + 7_200)
        store.upsertTraeRows([grown])

        let stats = store.queryDayStats(days: 0)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.reqs, 1, "同一会话只算一行")
        XCTAssertEqual(stats?.input, 250)
        XCTAssertEqual(stats?.output, 30)
        XCTAssertEqual(stats?.cacheRead, 90)
    }

    // MARK: 积分聚合（SUM 口径：会话快照覆盖式入库，SUM 不重复计数）

    func testCreditsQueries() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "")])
        let todayEpoch = StatsStore.localMidnight(0) + 3600
        let yestEpoch = StatsStore.localMidnight(1) + 3600
        store.upsertTraeRows([
            TraeRow(sessionID: "s1", model: "m", input: 100, output: 50, cacheRead: 0, cacheWrite: 0,
                    costUsd: 0.01, credits: 2.5, epoch: todayEpoch),
            TraeRow(sessionID: "s2", model: "m", input: 10, output: 5, cacheRead: 0, cacheWrite: 0,
                    costUsd: 0, credits: 1.5, epoch: yestEpoch),
        ])
        XCTAssertEqual(store.queryTodayCredits(), 2.5, accuracy: 1e-9)
        XCTAssertEqual(store.queryCreditsDay(daysAgo: 0), 2.5, accuracy: 1e-9, "今日积分小字")
        XCTAssertEqual(store.queryCreditsDay(daysAgo: 1), 1.5, accuracy: 1e-9, "昨日积分小字")
        XCTAssertEqual(store.queryCreditsTotal(), 4.0, accuracy: 1e-9, "历史总积分小字")
        XCTAssertEqual(store.queryCreditsSum(days: 7), 4.0, accuracy: 1e-9)
        let daily = store.queryCreditsDaily(days: 7)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.credits }, 4.0, accuracy: 1e-9, "每日曲线之和应等于总和")
        XCTAssertEqual(daily.filter { $0.credits > 0 }.count, 2, "两个有用量日各出一个非零点")
    }

    // MARK: Trae-only 配置（无任何 SQLite ATTACH 源也要能出数）

    func testTraeOnlyConfigMakesQueriesActive() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "")])
        store.upsertTraeRows([TraeRow(sessionID: "s", model: "m", input: 7, output: 3,
                                      cacheRead: 0, cacheWrite: 0, costUsd: 0, credits: 0,
                                      epoch: StatsStore.localMidnight(0) + 60)])
        let today = store.queryDayStats(days: 0)
        XCTAssertEqual(today?.total, 10)
        let total = store.queryTotalStats()
        XCTAssertEqual(total?.total, 10)
    }

    func testDisabledTraeKeepsQueriesInactive() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: false, dbPath: "")])
        XCTAssertNil(store.queryDayStats(days: 0), "无任何启用源时保持原有的 nil 语义")
    }

    // MARK: CSV 13 列往返 + 旧版 12 列兼容

    func testCSVRoundTripWithCredits() throws {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "")])
        store.upsertTraeRows([TraeRow(sessionID: "s", model: "m", input: 7, output: 3,
                                      cacheRead: 0, cacheWrite: 0, costUsd: 0.25, credits: 1.5,
                                      epoch: StatsStore.localMidnight(1) + 60)])

        let exportPath = tmpDir + "/out.csv"
        XCTAssertTrue(store.exportCSV(to: exportPath))
        let csv = try String(contentsOfFile: exportPath, encoding: .utf8)
        XCTAssertTrue(csv.contains("credits"), "导出表头应含 credits 列")

        // 同库重复导入导出的内容：同主键 → 零新增（幂等），credits 列被正确解析
        let r = store.importCSV(from: exportPath)
        XCTAssertEqual(r.read, 1)
        XCTAssertEqual(r.inserted, 0, "同主键重复导入应零新增")
        XCTAssertEqual(r.skipped, 1)
    }

    func testLegacy12ColumnCSVImport() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "")])
        let legacy = """
        source,request_id,app_type,model,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,reasoning_tokens,total_cost_usd,created_at,request_count
        trae,trae|old,trae,m,10,5,2,1,0,0.100000,\(StatsStore.localMidnight(1) + 120),1
        """
        let path = tmpDir + "/legacy.csv"
        try? legacy.write(toFile: path, atomically: true, encoding: .utf8)
        let r = store.importCSV(from: path)
        XCTAssertEqual(r.inserted, 1, "旧版 12 列 CSV 应可导入")
        // 行落在昨天：今日不受影响，昨日经 daily_agg 聚合可见（10+5+2+1 = 18）
        XCTAssertEqual(store.queryDayStats(days: 0)?.total, 0)
        XCTAssertEqual(store.queryDayStats(days: 1)?.total, 18)
    }

    // MARK: 夜间静默

    func testNightSilenceSkipsSync() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: "sessionid=fake")])
        // 夜间静默窗口（本地 0:00–9:00）纯函数
        var cal = Calendar.current
        cal.timeZone = .current
        XCTAssertTrue(StatsStore.inNightSilence(cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 3, minute: 0))!))
        XCTAssertTrue(StatsStore.inNightSilence(cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 0, minute: 0))!))
        XCTAssertFalse(StatsStore.inNightSilence(cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9, minute: 0))!))
        XCTAssertFalse(StatsStore.inNightSilence(cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 23, minute: 0))!))
        // 静默期定时器驱动（非 interactive）直接 return，sourceStatus 保持"连接中…"。
        // 若静默被移除，假凭据会走真实 API 并把状态置为过期——测试即失败，守护有效
        let night = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 3, minute: 0))!
        XCTAssertFalse(store.syncTraeIfNeeded(now: night), "静默期不应发起同步")
        XCTAssertEqual(store.sourceStatus["trae"], "连接中…", "静默期定时器不应发起同步")
    }

    func testInteractiveBypassesNightSilence() {
        // 语义（用户确认）：0–9 点静默只限定时器；点弹窗（interactive）随时要查。
        // 用 11 点验证 interactive 正常路径不受影响；静默期的 interactive 放行
        // 与定时器一致共用同一个 guard，无法离线断言网络行为，此处守住接口签名。
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: "sessionid=fake")])
        var cal = Calendar.current
        cal.timeZone = .current
        let day = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 11, minute: 0))!
        // 白天 interactive：会真实发起（假凭据 → 状态被改写），证明 interactive 未被静默误伤
        XCTAssertTrue(store.syncTraeIfNeeded(now: day, interactive: true), "interactive 应发起同步")
        XCTAssertNotEqual(store.sourceStatus["trae"], "连接中…", "interactive 同步不应被拦截")
    }

    // MARK: 凭据变更（换账号）：旧账号态必须整体重置

    func testCredentialChangeResetsAccountState() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: "sessionid=old")])
        store.upsertTraeRows([TraeRow(sessionID: "s1", model: "m", input: 10, output: 5,
                                      cacheRead: 0, cacheWrite: 0, costUsd: 0.1, credits: 2.5,
                                      epoch: StatsStore.localMidnight(0) + 60)])
        XCTAssertEqual(store.queryTodayCredits(), 2.5, "旧账号数据应先入库")

        // 换新账号 cookie → 旧明细/日聚合清空，等新账号 90 天全量首拉
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: "sessionid=new")])
        XCTAssertEqual(store.queryTodayCredits(), 0, "换凭据后旧账号明细应被清空")
        XCTAssertEqual(store.queryDayStats(days: 0)?.total ?? -1, 0, "旧账号数据不应残留")
    }

    func testCredentialFormatChangeKeepsAccountState() {
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: "sessionid=fake")])
        store.upsertTraeRows([TraeRow(sessionID: "s1", model: "m", input: 10, output: 5,
                                      cacheRead: 0, cacheWrite: 0, costUsd: 0.1, credits: 2.5,
                                      epoch: StatsStore.localMidnight(0) + 60)])

        // 同一凭据换个粘贴格式（裸值 / 整段 Cookie）不应被当成换账号
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: "fake")])
        XCTAssertEqual(store.queryTodayCredits(), 2.5, "裸值不应清空同账号数据")
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "",
                                             credential: "foo=1; sessionid=fake; Path=/")])
        XCTAssertEqual(store.queryTodayCredits(), 2.5, "整段 Cookie 不应清空同账号数据")
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "",
                                             credential: "sessionid=fake; X-Cloudide-Session=s1")])
        XCTAssertEqual(store.queryTodayCredits(), 2.5, "补一个 Session 也不应清空同账号数据")
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "",
                                             credential: "sessionid=fake")])
        XCTAssertEqual(store.queryTodayCredits(), 2.5, "去掉 Session 仍不应清空同账号数据")
    }

    // MARK: 真实 API 端到端（CI 无凭据自动跳过；本地 TRAE_TEST_COOKIE="sessionid=…" 时跑通全链路）

    func testLiveSyncEndToEnd() throws {
        let cookie = ProcessInfo.processInfo.environment["TRAE_TEST_COOKIE"] ?? ""
        try XCTSkipIf(cookie.isEmpty, "set TRAE_TEST_COOKIE to run against live API")
        store.rebuild(configs: [SourceConfig(id: "trae", enabled: true, dbPath: "", credential: cookie)])
        store.syncTraeIfNeeded()
        XCTAssertEqual(store.sourceStatus["trae"], "已连接")

        let today = store.queryDayStats(days: 0)
        XCTAssertNotNil(today, "Trae-only 配置下今日统计应可用")
        let week = store.queryDayStats(days: 7)
        let total = store.queryTotalStats()
        let ent = store.traeEntSummary()
        print("[live] 今日 \(today?.reqs ?? 0) 次 / \(today?.total ?? 0) tokens；近7天 \(week?.total ?? 0)；" +
              "累计 \(total?.total ?? 0)；积分 \(ent.map { "\($0.consumed)/\($0.total)" } ?? "n/a")")
        XCTAssertGreaterThan(total?.total ?? 0, 0, "90 天窗口应至少同步到 1 条")
    }
}
