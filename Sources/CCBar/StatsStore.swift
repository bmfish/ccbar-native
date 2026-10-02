import Cocoa
import SQLite3

// MARK: - 统计结果类型

/// 一天（或一段区间）的用量聚合。total 口径：input + output + 缓存读 + 缓存创建
struct DayStats: Equatable {
    let reqs: Int
    let input: Int64
    let output: Int64
    let cacheCreate: Int64
    let cacheRead: Int64
    var total: Int64 { input + output + cacheCreate + cacheRead }

    static func + (l: DayStats, r: DayStats) -> DayStats {
        DayStats(reqs: l.reqs + r.reqs, input: l.input + r.input, output: l.output + r.output,
                 cacheCreate: l.cacheCreate + r.cacheCreate, cacheRead: l.cacheRead + r.cacheRead)
    }
}

struct TotalStats: Equatable {
    let reqs: Int
    let total: Int64
}

struct ModelStat: Equatable {
    let model: String
    let input: Int64
    let output: Int64
    let total: Int64
}

struct SourceStat {
    let source: String
    let reqs: Int
    let total: Int64
}

// MARK: - 数据源适配器协议
//
// 每个外部统计库实现一个适配器：负责 ATTACH、把历史同步进 usage_log、
// 以及提供 usage_all 视图中"今日实时数据"的 UNION 段。
// 新增数据源（codex / opencode 等）只需实现本协议并注册到 SourceRegistry。

protocol SourceAdapter {
    /// 稳定标识，对应 Settings.SourceConfig.id
    var id: String { get }
    /// 界面显示名
    var name: String { get }
    /// 默认库路径
    var defaultPath: String { get }
    /// ATTACH 后的库别名
    var alias: String { get }
    /// 库文件里必须存在的表（用于判断源是否可用）
    var requiredTables: [String] { get }

    func attachSQL(fileURL: String) -> String
    /// 历史补账 SQL：同步 [fromEpoch, todayEpoch) 区间（本地时区的 0 点 epoch 秒，含回看重叠，INSERT OR IGNORE 幂等）
    func syncSQLs(alias: String, fromEpoch: Int64, todayEpoch: Int64) -> [String]
    /// usage_all 视图中该源"今日"数据的 UNION ALL 段。
    /// todayStartEpoch 由 StatsStore 用 Calendar 算好（本地今天 0 点）在构建视图时烘进去，
    /// 跨零点后由 refreshViewForNewDay 重建视图 —— 不在 SQL 里做时区运算（strftime 的
    /// localtime + %s 组合会偏移一个时区）。
    func todayFragment(alias: String, todayStartEpoch: Int64) -> String
}

// MARK: - 辅助

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - cc-switch 适配器

struct CCSwitchAdapter: SourceAdapter {
    let id = "ccswitch"
    let name = "cc-switch"
    let defaultPath = "\(NSHomeDirectory())/.cc-switch/cc-switch.db"
    let alias = "src_cc"
    let requiredTables = ["proxy_request_logs"]

    func attachSQL(fileURL: String) -> String {
        return "ATTACH DATABASE 'file:\(fileURL)?mode=ro' AS \(alias)"
    }

    func syncSQLs(alias: String, fromEpoch: Int64, todayEpoch: Int64) -> [String] {
        // 明细：只同步"昨天及更早"，今日走实时视图。
        // created_at 是 epoch 秒，用区间条件让源库索引可用，避免逐行 date() 全表扫描。
        let detail = """
        INSERT OR IGNORE INTO usage_log
            (source, request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd, created_at, request_count)
        SELECT
            'cc-switch', request_id, app_type, model, input_tokens, output_tokens,
            cache_read_tokens, cache_creation_tokens, 0,
            CAST(total_cost_usd AS REAL), created_at, 1
        FROM \(alias).proxy_request_logs
        WHERE created_at >= \(fromEpoch) AND created_at < \(todayEpoch)
        """
        // 历史聚合（早于本地已有明细最早一天的），展开成"每天每模型一行"的伪明细，
        // 请求侧无需再区分明细/聚合两套口径。created_at 取"该日期的本地正午"：
        // 先按 UTC 零点取 epoch，再补偿本地时区偏移 +12h，任意时区 date() 都落在原日期。
        let rollups = """
        INSERT OR IGNORE INTO usage_log
            (source, request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd, created_at, request_count)
        SELECT
            'cc-switch-rollup',
            'rollup|' || date || '|' || provider_id || '|' || model || '|' || request_model || '|' || pricing_model,
            app_type, model, input_tokens, output_tokens,
            cache_read_tokens, cache_creation_tokens, 0,
            CAST(total_cost_usd AS REAL),
            CAST(strftime('%s', date || ' 00:00:00') - (strftime('%s', 'now', 'localtime') - strftime('%s', 'now')) + 43200 AS INTEGER),
            request_count
        FROM \(alias).usage_daily_rollups
        WHERE date < (SELECT date(MIN(created_at), 'unixepoch', 'localtime')
                      FROM usage_log WHERE source = 'cc-switch')
        """
        return [detail, rollups]
    }

    func todayFragment(alias: String, todayStartEpoch: Int64) -> String {
        return """
        SELECT 'cc-switch' AS source, app_type, model, input_tokens, output_tokens,
               cache_read_tokens, cache_creation_tokens, 0 AS reasoning_tokens,
               CAST(total_cost_usd AS REAL) AS total_cost_usd, created_at, 1 AS request_count
        FROM \(alias).proxy_request_logs
        WHERE created_at >= \(todayStartEpoch)
        """
    }
}

// MARK: - ZCode 适配器

struct ZCodeAdapter: SourceAdapter {
    let id = "zcode"
    let name = "ZCode"
    let defaultPath = "\(NSHomeDirectory())/.zcode/cli/db/db.sqlite"
    let alias = "src_zc"
    let requiredTables = ["model_usage"]

    func attachSQL(fileURL: String) -> String {
        return "ATTACH DATABASE 'file:\(fileURL)?mode=ro' AS \(alias)"
    }

    func syncSQLs(alias: String, fromEpoch: Int64, todayEpoch: Int64) -> [String] {
        // ZCode 的 started_at 是毫秒，统一折成秒。
        // 口径：按 ZCode 官方统计（computed_total_tokens = input+output），
        // 缓存命中部分不计入用量，缓存列记 0（原始值仍在 ZCode 自己的库里）。
        let detail = """
        INSERT OR IGNORE INTO usage_log
            (source, request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd, created_at, request_count)
        SELECT
            'zcode', id, 'zcode', model_id, input_tokens, output_tokens,
            0, 0, reasoning_tokens, 0,
            started_at / 1000, 1
        FROM \(alias).model_usage
        WHERE status != 'running'
          AND started_at >= \(fromEpoch) * 1000 AND started_at < \(todayEpoch) * 1000
        """
        return [detail]
    }

    func todayFragment(alias: String, todayStartEpoch: Int64) -> String {
        return """
        SELECT 'zcode' AS source, 'zcode' AS app_type, model_id AS model,
               input_tokens, output_tokens,
               0 AS cache_read_tokens,
               0 AS cache_creation_tokens,
               reasoning_tokens, 0.0 AS total_cost_usd,
               started_at / 1000 AS created_at, 1 AS request_count
        FROM \(alias).model_usage
        WHERE status != 'running'
          AND started_at >= \(todayStartEpoch) * 1000
        """
    }
}

// MARK: - 适配器注册表（新数据源在这里加一行）

enum SourceRegistry {
    static let adapters: [SourceAdapter] = [CCSwitchAdapter(), ZCodeAdapter()]

    static func adapter(for id: String) -> SourceAdapter? {
        return adapters.first { $0.id == id }
    }
}

// MARK: - 统计库
//
// 自建库（Application Support/ccbar/ccbar.db）为主连接：
//   - usage_log    统一明细（昨天及更早，每日懒惰补账）
//   - meta         各源同步水位
//   - usage_all    视图 = 自家历史 + 各启用源"今日"实时数据
// 外部源库一律以只读方式 ATTACH，绝不写入。
//
// 线程模型：定时器查询走后台串行队列，rebuild 在主线程，detail 窗口在主线程直连。
// 全部入口经 lock 串行，底层连接又开了 FULLMUTEX，双重保险。

final class StatsStore {
    private(set) var handle: OpaquePointer?
    private(set) var attachedAdapters: [SourceAdapter] = []
    /// 每个数据源的连接诊断信息（设置页展示）：已连接 / 未启用 / 具体失败原因
    private(set) var sourceStatus: [String: String] = [:]

    private let lock = NSLock()

    /// 测试注入自定义库路径；nil 用默认路径（Application Support/ccbar/ccbar.db）
    private let pathOverride: String?

    init(storePath: String? = nil) {
        self.pathOverride = storePath
    }

    /// 视图构建时的"今天"（yyyy-MM-dd）；外部源"今日"分支的 epoch 边界烘在视图里，
    /// 跨零点后要靠 refreshViewForNewDay 重建
    private var viewDay: String = ""

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var storePath: String {
        let dir = "\(NSHomeDirectory())/Library/Application Support/ccbar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/ccbar.db"
    }

    /// 本地时区 N 天前（0=今天）0 点的 epoch 秒，作为查询/同步的区间边界
    static func localMidnight(_ daysAgo: Int, now: Date = Date()) -> Int64 {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return Int64(cal.startOfDay(for: day).timeIntervalSince1970)
    }

    /// epoch → 本地日期字符串（daily_agg 主键格式 yyyy-MM-dd）
    static func dayString(fromEpoch e: Int64) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(e)))
    }

    /// 把 URI 里会破坏 file: 语法的字符转义（含单引号——URL 里转成 %27，SQLite 解 URI 时还原）
    private func uriEscape(_ path: String) -> String {
        return path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "?#'").inverted) ?? path
    }

    // MARK: 基础执行（仅供内部已持锁的路径调用）

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = handle else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func scalarInt(_ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard let db = handle, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    /// 绑定 int64 参数并逐行回调（需已持锁）
    private func forEachRow(_ sql: String, binds: [Int64] = [], _ visit: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard let db = handle, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in binds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), v)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            visit(stmt!)
        }
    }

    /// 绑定文本参数并逐行回调（需已持锁）
    private func forEachRowText(_ sql: String, binds: [String] = [], _ visit: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard let db = handle, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            visit(stmt!)
        }
    }

    /// 单行聚合查询，返回首行前 columns 列（需已持锁）
    private func aggregateRow(_ sql: String, binds: [Int64] = [], columns: Int) -> [Int64]? {
        var out: [Int64]?
        forEachRow(sql, binds: binds) { stmt in
            if out == nil {
                out = (0..<columns).map { sqlite3_column_int64(stmt, Int32($0)) }
            }
        }
        return out
    }

    /// 单行聚合查询（文本绑定），返回首行前 columns 列（需已持锁）
    private func aggregateRowText(_ sql: String, binds: [String] = [], columns: Int) -> [Int64]? {
        var out: [Int64]?
        forEachRowText(sql, binds: binds) { stmt in
            if out == nil {
                out = (0..<columns).map { sqlite3_column_int64(stmt, Int32($0)) }
            }
        }
        return out
    }

    // MARK: 重建连接（启动、设置保存后调用）

    func rebuild(configs: [SourceConfig]) {
        lock.lock(); defer { lock.unlock() }

        close()

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let path = pathOverride ?? Self.storePath
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            print("[ccBar] 无法打开自建统计库: \(path)")
            handle = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        // 源库正被其宿主应用写入时只读 ATTACH 也可能撞 SQLITE_BUSY，等 2 秒而不是直接失败
        exec("PRAGMA busy_timeout = 2000")

        guard exec("""
        CREATE TABLE IF NOT EXISTS usage_log (
            source TEXT NOT NULL,
            request_id TEXT NOT NULL,
            app_type TEXT,
            model TEXT,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            total_cost_usd REAL NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            request_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (source, request_id)
        )
        """) else {
            print("[ccBar] 建 usage_log 失败")
            return
        }
        exec("CREATE INDEX IF NOT EXISTS idx_usage_created ON usage_log(created_at)")
        exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")

        // 每日聚合缓存：区间/总量/按月查询直接读它，不再扫明细。
        // (date, source) 主键；meta 标记控制升级后一次性全量回填。
        exec("""
        CREATE TABLE IF NOT EXISTS daily_agg (
            date TEXT NOT NULL,
            source TEXT NOT NULL,
            reqs INTEGER NOT NULL DEFAULT 0,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_create INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (date, source)
        )
        """)
        if metaGet("daily_agg_full") == "" {
            exec("""
            INSERT OR REPLACE INTO daily_agg (date, source, reqs, input, output, cache_create, cache_read)
            SELECT date(created_at, 'unixepoch', 'localtime'), source,
                   SUM(request_count), SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_creation_tokens), SUM(cache_read_tokens)
            FROM usage_log GROUP BY 1, 2
            """)
            metaSet("daily_agg_full", value: "1")
        }

        // ATTACH 各数据源并记录连接状态（供设置页展示）
        attachedAdapters.removeAll()
        sourceStatus.removeAll()
        for config in configs {
            guard let adapter = SourceRegistry.adapter(for: config.id) else { continue }
            guard config.enabled else {
                sourceStatus[config.id] = "未启用"
                continue
            }
            if let error = attach(adapter: adapter, path: config.dbPath) {
                sourceStatus[config.id] = error
            } else {
                attachedAdapters.append(adapter)
                sourceStatus[config.id] = "已连接"
            }
        }

        rebuildView()
    }

    /// 成功返回 nil，失败返回诊断信息
    private func attach(adapter: SourceAdapter, path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            print("[ccBar] 数据源 \(adapter.name) 文件不存在，跳过: \(path)")
            return "文件不存在"
        }
        if !exec(adapter.attachSQL(fileURL: uriEscape(path))) {
            // 源库是 WAL 模式且 -wal 文件不在（源应用已关闭）时只读 ATTACH 会失败，
            // 回退普通 ATTACH——本应用保证绝不写源库
            let plain = "ATTACH DATABASE '\(uriEscape(path))' AS \(adapter.alias)"
            guard exec(plain) else {
                print("[ccBar] 数据源 \(adapter.name) ATTACH 失败，跳过")
                return "ATTACH 失败（库可能被占用或损坏）"
            }
        }
        // 表都齐才算可用
        let list = adapter.requiredTables.joined(separator: "','")
        let found = scalarInt("SELECT COUNT(*) FROM \(adapter.alias).sqlite_master WHERE type='table' AND name IN ('\(list)')")
        if found < Int64(adapter.requiredTables.count) {
            print("[ccBar] 数据源 \(adapter.name) 缺少必需表，跳过")
            exec("DETACH DATABASE \(adapter.alias)")
            return "缺少必需表"
        }
        return nil
    }

    /// usage_all = 自家历史 + 各源今日实时。设置变化（启停/换路径）后重建。
    private func rebuildView() {
        viewDay = Self.dayFormatter.string(from: Date())
        let todayStart = Self.localMidnight(0)

        exec("DROP VIEW IF EXISTS temp.usage_all")
        var parts = ["""
        SELECT source, app_type, model, input_tokens, output_tokens,
               cache_read_tokens, cache_creation_tokens, reasoning_tokens,
               total_cost_usd, created_at, request_count
        FROM usage_log
        """]
        for adapter in attachedAdapters {
            parts.append(adapter.todayFragment(alias: adapter.alias, todayStartEpoch: todayStart))
        }
        guard exec("CREATE TEMP VIEW usage_all AS " + parts.joined(separator: " UNION ALL ")) else {
            print("[ccBar] 创建 usage_all 视图失败")
            return
        }
    }

    /// 跨零点后重建视图（外部源"今日"分支的边界是构建时烘进去的 epoch，不能过夜）。
    /// 随每次 syncIfNeeded 检查，零点后最多滞后一个刷新周期。
    private func refreshViewForNewDayIfNeeded() {
        guard !attachedAdapters.isEmpty else { return }
        guard viewDay != Self.dayFormatter.string(from: Date()) else { return }
        rebuildView()
    }

    func close() {
        if let db = handle {
            sqlite3_close_v2(db)
        }
        handle = nil
        attachedAdapters.removeAll()
    }

    // MARK: 懒惰补账
    //
    // meta 里记录每个源已同步到的"最后一个完整日"（昨天及更早）。
    // 落后于昨天就补 [水位-1天, 昨天]，窗口多回看一天防跨零点迟到行；
    // 首次水位为空 → 从 1970 全量回填。INSERT OR IGNORE 幂等。
    // 单个源失败只跳过该源（水位不推进，下个刷新重试），不影响其余源。

    func syncIfNeeded() {
        lock.lock(); defer { lock.unlock() }

        refreshViewForNewDayIfNeeded()
        guard !attachedAdapters.isEmpty else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }
        let yesterdayStr = fmt.string(from: yesterday)
        let todayEpoch = Self.localMidnight(0)

        for adapter in attachedAdapters {
            let key = "synced_day_\(adapter.id)"
            let waterLine = metaGet(key)
            guard waterLine < yesterdayStr else { continue }   // 已是最新

            // 回看一天；首次全量
            var fromEpoch: Int64 = 0
            if !waterLine.isEmpty, let d = fmt.date(from: waterLine),
               let back = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                fromEpoch = Self.localMidnight(0, now: back)
            }

            var ok = true
            for sql in adapter.syncSQLs(alias: adapter.alias, fromEpoch: fromEpoch, todayEpoch: todayEpoch) {
                if !exec(sql) {
                    print("[ccBar] \(adapter.name) 同步失败: \(sql.prefix(80))…")
                    ok = false
                    break
                }
            }
            if ok {
                metaSet(key, value: yesterdayStr)
                refreshDailyAgg(fromEpoch: fromEpoch, toEpoch: todayEpoch)
            }
        }
    }

    /// 重算 [fromEpoch, toEpoch) 窗口的每日聚合（数据源：usage_log 明细，OR REPLACE 自愈式覆盖）
    private func refreshDailyAgg(fromEpoch: Int64, toEpoch: Int64) {
        exec("""
        INSERT OR REPLACE INTO daily_agg (date, source, reqs, input, output, cache_create, cache_read)
        SELECT date(created_at, 'unixepoch', 'localtime'), source,
               SUM(request_count), SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_read_tokens)
        FROM usage_log
        WHERE created_at >= \(fromEpoch) AND created_at < \(toEpoch)
        GROUP BY 1, 2
        """)
    }

    /// daily_agg 区间汇总（仅覆盖"昨天及更早"；今日数据由调用方叠加实时值）。
    /// 聚合无 GROUP BY 时即使空区间也会返回一行全 0。
    private func dailyAggSum(fromDay: String, toDay: String) -> DayStats? {
        guard handle != nil else { return nil }
        guard let row = aggregateRowText("""
        SELECT COALESCE(SUM(reqs),0), COALESCE(SUM(input),0), COALESCE(SUM(output),0),
               COALESCE(SUM(cache_create),0), COALESCE(SUM(cache_read),0)
        FROM daily_agg WHERE date >= ? AND date <= ?
        """, binds: [fromDay, toDay], columns: 5) else { return nil }
        return DayStats(reqs: Int(row[0]), input: row[1], output: row[2], cacheCreate: row[3], cacheRead: row[4])
    }

    private func metaGet(_ key: String) -> String {
        var stmt: OpaquePointer?
        guard let db = handle, sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return ""
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
        return ""
    }

    private func metaSet(_ key: String, value: String) {
        var stmt: OpaquePointer?
        guard let db = handle, sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    // MARK: 查询
    //
    // 今日数据来自视图的外部源分支（内部按今日 0 点过滤，走索引）；
    // 历史区间读 daily_agg 聚合表（补账时维护），不再扫明细。

    private static let aggColumns = """
        COALESCE(SUM(request_count), 0),
        COALESCE(SUM(input_tokens), 0),
        COALESCE(SUM(output_tokens), 0),
        COALESCE(SUM(cache_creation_tokens), 0),
        COALESCE(SUM(cache_read_tokens), 0)
        """

    private static let zeroStats = DayStats(reqs: 0, input: 0, output: 0, cacheCreate: 0, cacheRead: 0)

    /// 今日实时聚合（usage_all 的"今日"段）
    private func todayLive(now: Date) -> DayStats? {
        let sql = "SELECT \(Self.aggColumns) FROM usage_all WHERE created_at >= ? AND created_at < ?"
        guard let row = aggregateRow(sql, binds: [Self.localMidnight(0, now: now), Self.localMidnight(-1, now: now)], columns: 5) else { return nil }
        return DayStats(reqs: Int(row[0]), input: row[1], output: row[2], cacheCreate: row[3], cacheRead: row[4])
    }

    /// days == 0 今日（实时）；days == 1 昨日；其余：近 N 天（含今天，自 N 天前 0 点起）
    func queryDayStats(days: Int) -> DayStats? {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, !attachedAdapters.isEmpty else { return nil }

        let now = Date()
        if days == 0 {
            return todayLive(now: now)
        }
        if days == 1 {
            let y = Self.dayString(fromEpoch: Self.localMidnight(1, now: now))
            return dailyAggSum(fromDay: y, toDay: y) ?? Self.zeroStats
        }
        let from = Self.dayString(fromEpoch: Self.localMidnight(days, now: now))
        let to = Self.dayString(fromEpoch: Self.localMidnight(1, now: now))
        let history = dailyAggSum(fromDay: from, toDay: to) ?? Self.zeroStats
        return history + (todayLive(now: now) ?? Self.zeroStats)
    }

    func queryModelBreakdown() -> [ModelStat] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }

        var result: [ModelStat] = []
        forEachRow("""
        SELECT model, COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
               COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY model ORDER BY 4 DESC
        """, binds: [Self.localMidnight(0), Self.localMidnight(-1)]) { stmt in
            result.append(ModelStat(model: String(cString: sqlite3_column_text(stmt, 0)),
                                    input: sqlite3_column_int64(stmt, 1),
                                    output: sqlite3_column_int64(stmt, 2),
                                    total: sqlite3_column_int64(stmt, 3)))
        }
        return result
    }

    /// 今日"工时"：今天第一条请求距现在的小时数
    func queryWorkHours() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return nil }

        var hours: Double?
        forEachRow("SELECT MIN(created_at) FROM usage_all WHERE created_at >= ?",
                   binds: [Self.localMidnight(0)]) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                let start = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
                hours = Date().timeIntervalSince(start) / 3600
            }
        }
        return hours
    }

    /// 历史总量：daily_agg 全量 + 今日实时
    func queryTotalStats() -> TotalStats? {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, !attachedAdapters.isEmpty else { return nil }

        guard let history = dailyAggSum(fromDay: "0000-01-01", toDay: "9999-12-31") else { return nil }
        let all = history + (todayLive(now: Date()) ?? Self.zeroStats)
        return TotalStats(reqs: all.reqs, total: all.total)
    }

    /// 按月汇总（历史走 daily_agg，今日由调用方叠加），月份倒序，最多 limit 个月
    func queryMonthlyTotals(limit: Int = 36) -> [(month: String, reqs: Int, token: Int64, cache: Int64)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(month: String, reqs: Int, token: Int64, cache: Int64)] = []
        forEachRowText("""
        SELECT substr(date, 1, 7), COALESCE(SUM(reqs),0),
               COALESCE(SUM(input + output + cache_create + cache_read),0), COALESCE(SUM(cache_read),0)
        FROM daily_agg GROUP BY 1 ORDER BY 1 DESC LIMIT \(max(1, limit))
        """) { stmt in
            result.append((month: String(cString: sqlite3_column_text(stmt, 0)),
                           reqs: Int(sqlite3_column_int64(stmt, 1)),
                           token: sqlite3_column_int64(stmt, 2),
                           cache: sqlite3_column_int64(stmt, 3)))
        }
        return result
    }

    /// 今日各数据源分账
    func querySourceBreakdown() -> [SourceStat] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, !attachedAdapters.isEmpty else { return [] }

        var result: [SourceStat] = []
        forEachRow("""
        SELECT source, COALESCE(SUM(request_count), 0),
               COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY source ORDER BY 3 DESC
        """, binds: [Self.localMidnight(0), Self.localMidnight(-1)]) { stmt in
            result.append(SourceStat(source: String(cString: sqlite3_column_text(stmt, 0)),
                                     reqs: Int(sqlite3_column_int64(stmt, 1)),
                                     total: sqlite3_column_int64(stmt, 2)))
        }
        return result
    }
}
