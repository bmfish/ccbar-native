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

    // MARK: 备份

    // MARK: 导出 / 导入（幂等）

    /// 明细表列头（导出 CSV 用，导入按此顺序解析）
    private static let exportColumns = ["source", "request_id", "app_type", "model",
                                        "input_tokens", "output_tokens", "cache_read_tokens",
                                        "cache_creation_tokens", "reasoning_tokens",
                                        "total_cost_usd", "created_at", "request_count"]

    /// 导出 usage_log 全量明细为 CSV（Excel 可开；字段含逗号/引号时按 RFC4180 转义）
    func exportCSV(to path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return false }

        var stmt: OpaquePointer?
        let sql = """
        SELECT source, request_id, app_type, model, input_tokens, output_tokens,
               cache_read_tokens, cache_creation_tokens, reasoning_tokens,
               total_cost_usd, created_at, request_count
        FROM usage_log ORDER BY created_at
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        var out = Self.exportColumns.joined(separator: ",") + "\n"
        while sqlite3_step(stmt) == SQLITE_ROW {
            var fields: [String] = []
            for i in 0..<12 {
                switch i {
                case 4...8, 10, 11:
                    fields.append(String(sqlite3_column_int64(stmt, Int32(i))))
                case 9:
                    fields.append(String(format: "%.6f", sqlite3_column_double(stmt, Int32(i))))
                default:
                    let text = sqlite3_column_text(stmt, Int32(i)).map {
                        String(cString: $0)
                    } ?? ""
                    fields.append(Self.csvEscape(text))
                }
            }
            out += fields.joined(separator: ",") + "\n"
        }
        do {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("[ccBar] 导出失败: \(error.localizedDescription)")
            return false
        }
    }

    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// 从 CSV 导入明细（幂等）：主键 (source, request_id) 去重，重复/非法行跳过；
    /// 导入后按受影响窗口重建 daily_agg。
    /// - Returns: (读取行数, 新增行数, 跳过行数)
    func importCSV(from path: String) -> (read: Int, inserted: Int, skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return (0, 0, 0) }
        guard let raw = FileManager.default.contents(atPath: path),
              let text = String(data: raw, encoding: .utf8) else { return (0, 0, 0) }

        let records = Self.parseCSV(text)
        guard records.count > 1 else { return (0, 0, 0) }

        var stmt: OpaquePointer?
        let sql = """
        INSERT OR IGNORE INTO usage_log
            (source, request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd,
             created_at, request_count)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0) }
        defer { sqlite3_finalize(stmt) }

        var read = 0, inserted = 0, skipped = 0
        var minEpoch: Int64?
        var maxEpoch: Int64?

        for record in records.dropFirst() {
            guard record.count == 12,
                  let input = Int64(record[4]), let output = Int64(record[5]),
                  let cacheRead = Int64(record[6]), let cacheCreate = Int64(record[7]),
                  let reasoning = Int64(record[8]), let cost = Double(record[9]),
                  let epoch = Int64(record[10]), let reqCount = Int64(record[11]),
                  !record[0].isEmpty, !record[1].isEmpty else {
                skipped += 1
                continue
            }
            read += 1
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, record[0], -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, record[1], -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, record[2], -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, record[3], -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 5, input)
            sqlite3_bind_int64(stmt, 6, output)
            sqlite3_bind_int64(stmt, 7, cacheRead)
            sqlite3_bind_int64(stmt, 8, cacheCreate)
            sqlite3_bind_int64(stmt, 9, reasoning)
            sqlite3_bind_double(stmt, 10, cost)
            sqlite3_bind_int64(stmt, 11, epoch)
            sqlite3_bind_int64(stmt, 12, reqCount)
            if sqlite3_step(stmt) == SQLITE_DONE {
                if sqlite3_changes(db) > 0 { inserted += 1 } else { skipped += 1 }
            } else {
                skipped += 1
            }
            minEpoch = min(minEpoch ?? epoch, epoch)
            maxEpoch = max(maxEpoch ?? epoch, epoch)
        }

        // 导入行并入聚合缓存（含跨天余量），幂等重算
        if let mn = minEpoch, let mx = maxEpoch {
            refreshDailyAgg(fromEpoch: mn, toEpoch: mx + 86400)
        }
        return (read, inserted, skipped)
    }

    /// 轻量 CSV 解析（RFC4180：双引号转义、字段内逗号/换行）
    static func parseCSV(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let peek = nextChar() {
                        if peek == "\"" { field.append("\"") }   // 转义引号
                        else { inQuotes = false; pending = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                record.append(field)
                field = ""
            } else if ch == "\n" {
                record.append(field)
                field = ""
                if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
                record = []
            } else if ch == "\r" {
                continue   // \r\n 当 \n 处理
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
        }
        return records
    }

    /// 备份统计库到目标路径（VACUUM INTO 生成紧凑的独立副本，连接打开中也可安全执行）
    func backup(to path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_DONE
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
        return sourceBreakdownUnlocked()
    }

    /// 无锁版（调用方必须已持锁；NSLock 不可重入，别在持锁方法里调公开查询）
    private func sourceBreakdownUnlocked() -> [SourceStat] {
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

    // MARK: 洞察中心查询
    //
    // 费用类走 usage_log/usage_all（daily_agg 没有费用列）：
    // epoch 区间条件走 created_at 索引，洞察窗口偶发查询，量级无压力。
    // 历史 token 类优先 daily_agg，今日实时统一补查。

    /// 近 N 天（含今天）总费用（USD）
    func queryCost(days: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return 0 }
        var total = 0.0
        forEachRow("""
        SELECT COALESCE(SUM(total_cost_usd), 0) FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        """, binds: [Self.localMidnight(days), Self.localMidnight(-1)]) { stmt in
            total = sqlite3_column_double(stmt, 0)
        }
        return total
    }

    /// 近 N 天（含今天）每日费用曲线，日期升序（可能有空洞，调用方补零）
    func queryCostDaily(days: Int) -> [(date: String, cost: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(date: String, cost: Double)] = []
        forEachRow("""
        SELECT date(created_at, 'unixepoch', 'localtime'), COALESCE(SUM(total_cost_usd), 0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY 1 ORDER BY 1
        """, binds: [Self.localMidnight(days), Self.localMidnight(-1)]) { stmt in
            result.append((String(cString: sqlite3_column_text(stmt, 0)), sqlite3_column_double(stmt, 1)))
        }
        return result
    }

    /// 近 N 天（含今天）按模型费用排行
    func queryCostByModel(days: Int, limit: Int = 8) -> [(model: String, cost: Double, token: Int64)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(model: String, cost: Double, token: Int64)] = []
        forEachRow("""
        SELECT model, COALESCE(SUM(total_cost_usd), 0),
               COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY model ORDER BY 2 DESC LIMIT \(max(1, limit))
        """, binds: [Self.localMidnight(days), Self.localMidnight(-1)]) { stmt in
            result.append((model: String(cString: sqlite3_column_text(stmt, 0)),
                           cost: sqlite3_column_double(stmt, 1),
                           token: sqlite3_column_int64(stmt, 2)))
        }
        return result
    }

    /// 连续使用天数（今天没用就从昨天起算）
    func queryStreak() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return 0 }
        var dates: [String] = []
        forEachRowText("""
        SELECT DISTINCT date FROM daily_agg
        WHERE input + output + cache_create + cache_read > 0 ORDER BY 1 DESC LIMIT 400
        """) { stmt in
            dates.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var expected = Calendar.current.startOfDay(for: Date())
        if dates.first != fmt.string(from: expected) {
            expected = Calendar.current.date(byAdding: .day, value: -1, to: expected)!
        }
        var streak = 0
        for d in dates {
            if d == fmt.string(from: expected) {
                streak += 1
                expected = Calendar.current.date(byAdding: .day, value: -1, to: expected)!
            } else if d > fmt.string(from: expected) {
                continue   // 游离的未来日期，跳过不打断
            } else {
                break
            }
        }
        return streak
    }

    /// 周环比：近 7 天（含今天） vs 之前 7 天
    func queryWeeklyDelta() -> (thisWeek: Int64, lastWeek: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return (0, 0) }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let this = dailyAggSum(fromDay: fmt.string(from: Date(timeIntervalSince1970: TimeInterval(Self.localMidnight(6)))),
                               toDay: fmt.string(from: Date(timeIntervalSince1970: TimeInterval(Self.localMidnight(1))))) ?? Self.zeroStats
        let last = dailyAggSum(fromDay: fmt.string(from: Date(timeIntervalSince1970: TimeInterval(Self.localMidnight(13)))),
                               toDay: fmt.string(from: Date(timeIntervalSince1970: TimeInterval(Self.localMidnight(7))))) ?? Self.zeroStats
        let today = todayLive(now: Date()) ?? Self.zeroStats
        return (this.total + today.total, last.total)
    }

    /// 近 N 天单日峰值（今日实时也参与竞争），无数据返回 nil
    func queryPeakDay(days: Int) -> (date: String, token: Int64)? {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var peak: (date: String, token: Int64)?
        var stmt: OpaquePointer?
        let sql = """
        SELECT date, COALESCE(SUM(input + output + cache_create + cache_read), 0) AS t
        FROM daily_agg WHERE date >= ? GROUP BY date ORDER BY t DESC LIMIT 1
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, fmt.string(from: Date(timeIntervalSince1970: TimeInterval(Self.localMidnight(days)))), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            peak = (String(cString: sqlite3_column_text(stmt, 0)), sqlite3_column_int64(stmt, 1))
        }
        if let today = todayLive(now: Date()), today.total > (peak?.token ?? 0) {
            peak = (fmt.string(from: Date()), today.total)
        }
        return peak
    }

    /// 近 N 天应用（app_type）每日 token，今日实时按 app_type 细分补一行
    func queryAppDaily(days: Int) -> [(date: String, app: String, token: Int64)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(date: String, app: String, token: Int64)] = []
        forEachRow("""
        SELECT date(created_at, 'unixepoch', 'localtime'),
               COALESCE(NULLIF(app_type, ''), 'unknown'),
               COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_log
        WHERE created_at >= ? AND created_at < ?
        GROUP BY 1, 2
        """, binds: [Self.localMidnight(days), Self.localMidnight(-1)]) { stmt in
            result.append((String(cString: sqlite3_column_text(stmt, 0)),
                           String(cString: sqlite3_column_text(stmt, 1)),
                           sqlite3_column_int64(stmt, 2)))
        }
        // 今日实时按 app_type 细分
        forEachRow("""
        SELECT COALESCE(NULLIF(app_type, ''), 'unknown'),
               COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all WHERE created_at >= ? AND created_at < ?
        GROUP BY 1
        """, binds: [Self.localMidnight(0), Self.localMidnight(-1)]) { stmt in
            let token = sqlite3_column_int64(stmt, 1)
            guard token > 0 else { return }
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            result.append((fmt.string(from: Date()),
                           String(cString: sqlite3_column_text(stmt, 0)), token))
        }
        return result
    }

    /// 近 N 天每日 token 构成（输入/输出/缓存读/缓存创建），含今日实时，日期升序
    func queryCompositionDaily(days: Int) -> [(date: String, input: Int64, output: Int64, cacheRead: Int64, cacheCreate: Int64)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(date: String, input: Int64, output: Int64, cacheRead: Int64, cacheCreate: Int64)] = []
        let from = Self.dayString(fromEpoch: Self.localMidnight(days))
        forEachRowText("""
        SELECT date, COALESCE(SUM(input),0), COALESCE(SUM(output),0),
               COALESCE(SUM(cache_read),0), COALESCE(SUM(cache_create),0)
        FROM daily_agg WHERE date >= '\(from)' GROUP BY date ORDER BY date
        """) { stmt in
            result.append((String(cString: sqlite3_column_text(stmt, 0)),
                           sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2),
                           sqlite3_column_int64(stmt, 3), sqlite3_column_int64(stmt, 4)))
        }
        if let t = todayLive(now: Date()), t.total > 0 {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            result.append((fmt.string(from: Date()), t.input, t.output, t.cacheRead, t.cacheCreate))
        }
        return result
    }

    /// 本月进度：月初至昨日累计 + 今日实时、已过天数、当月总天数
    func queryMonthProgress() -> (mtd: Int64, daysElapsed: Int, daysInMonth: Int) {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return (0, 0, 30) }
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let first = cal.date(from: comps)!
        guard let nextMonth = cal.date(byAdding: .month, value: 1, to: first),
              let lastDay = cal.date(byAdding: .day, value: -1, to: nextMonth) else { return (0, 0, 30) }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let monthStats = dailyAggSum(fromDay: fmt.string(from: first),
                                     toDay: fmt.string(from: lastDay)) ?? Self.zeroStats
        let today = todayLive(now: now) ?? Self.zeroStats
        let daysElapsed = max(cal.component(.day, from: now), 1)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        return (monthStats.total + today.total, daysElapsed, daysInMonth)
    }

    /// 近 N 天（含今天）使用量最大的模型
    func queryTopModel(days: Int) -> (model: String, token: Int64)? {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return nil }
        var top: (model: String, token: Int64)?
        forEachRow("""
        SELECT model, COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0) AS t
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY model ORDER BY t DESC LIMIT 1
        """, binds: [Self.localMidnight(days), Self.localMidnight(-1)]) { stmt in
            top = (String(cString: sqlite3_column_text(stmt, 0)), sqlite3_column_int64(stmt, 1))
        }
        return top
    }

    /// 近 N 天时段分布（小时 → token）。本地时区偏移烘进参数，避免逐行 localtime
    func queryHourHistogram(days: Int) -> [Int: Int64] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [:] }
        let offset = Int64(TimeZone.current.secondsFromGMT())
        var out: [Int: Int64] = [:]
        forEachRow("""
        SELECT ((created_at + ?) % 86400) / 3600,
               COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens), 0)
        FROM usage_all
        WHERE created_at >= ? AND created_at < ?
        GROUP BY 1
        """, binds: [offset, Self.localMidnight(days), Self.localMidnight(-1)]) { stmt in
            out[Int(sqlite3_column_int64(stmt, 0))] = sqlite3_column_int64(stmt, 1)
        }
        return out
    }

    /// 近 N 天每日总 token（跨渠道，含今天实时），日期升序
    func queryDailyTokens(days: Int) -> [(date: String, token: Int64)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(date: String, token: Int64)] = []
        let from = Self.dayString(fromEpoch: Self.localMidnight(days))
        forEachRowText("""
        SELECT date, COALESCE(SUM(input + output + cache_create + cache_read), 0)
        FROM daily_agg WHERE date >= '\(from)' GROUP BY date ORDER BY date
        """) { stmt in
            result.append((String(cString: sqlite3_column_text(stmt, 0)), sqlite3_column_int64(stmt, 1)))
        }
        if let today = todayLive(now: Date()), today.total > 0 {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            result.append((fmt.string(from: Date()), today.total))
        }
        return result
    }

    /// 近 N 天渠道每日 token（daily_agg 自带 source 维度），今日实时按源补一行
    func queryChannelDaily(days: Int) -> [(date: String, source: String, token: Int64)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(date: String, source: String, token: Int64)] = []
        let from = Self.dayString(fromEpoch: Self.localMidnight(days))
        forEachRowText("""
        SELECT date, source, COALESCE(SUM(input + output + cache_create + cache_read), 0)
        FROM daily_agg WHERE date >= '\(from)'
        GROUP BY date, source ORDER BY date
        """) { stmt in
            result.append((String(cString: sqlite3_column_text(stmt, 0)),
                           String(cString: sqlite3_column_text(stmt, 1)),
                           sqlite3_column_int64(stmt, 2)))
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let todaySources = sourceBreakdownUnlocked()
        for s in todaySources where s.total > 0 {
            result.append((today, s.source, s.total))
        }
        return result
    }

    /// 今日请求流水（最新在前）：时间 / 模型 / 来源 / token / 费用
    func queryTodayTimeline(limit: Int = 800) -> [(time: Int, model: String, source: String, token: Int64, cost: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil else { return [] }
        var result: [(time: Int, model: String, source: String, token: Int64, cost: Double)] = []
        forEachRow("""
        SELECT created_at, model, source,
               COALESCE(input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens, 0),
               COALESCE(total_cost_usd, 0)
        FROM usage_all
        WHERE created_at >= ?
        ORDER BY created_at DESC LIMIT \(max(1, limit))
        """, binds: [Self.localMidnight(0)]) { stmt in
            let model = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? "-" : String(cString: sqlite3_column_text(stmt, 1))
            result.append((time: Int(sqlite3_column_int64(stmt, 0)),
                           model: model,
                           source: String(cString: sqlite3_column_text(stmt, 2)),
                           token: sqlite3_column_int64(stmt, 3),
                           cost: sqlite3_column_double(stmt, 4)))
        }
        return result
    }
}
