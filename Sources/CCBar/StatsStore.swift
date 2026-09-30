import Cocoa
import SQLite3

// MARK: - 数据源适配器协议
//
// 每个外部统计库实现一个适配器：负责 ATTACH、把历史同步进 usage_log、
// 以及提供 usage_all 视图中"今日实时数据"的 UNION 段。
// 新增数据源（codex / opencode 等）只需实现本协议并注册到 SourceAdapter.registry。

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
    /// 历史补账 SQL（按本地日期字符串 fromDay 起，含回看重叠，INSERT OR IGNORE 幂等）
    func syncSQLs(alias: String, fromDay: String, today: String) -> [String]
    /// usage_all 视图中该源"今日"数据的 UNION ALL 段
    func todayFragment(alias: String) -> String
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

    func syncSQLs(alias: String, fromDay: String, today: String) -> [String] {
        // 明细：只同步"昨天及更早"，今日走实时视图
        let detail = """
        INSERT OR IGNORE INTO usage_log
            (source, request_id, app_type, model, input_tokens, output_tokens,
             cache_read_tokens, cache_creation_tokens, reasoning_tokens, total_cost_usd, created_at, request_count)
        SELECT
            'cc-switch', request_id, app_type, model, input_tokens, output_tokens,
            cache_read_tokens, cache_creation_tokens, 0,
            CAST(total_cost_usd AS REAL), created_at, 1
        FROM \(alias).proxy_request_logs
        WHERE date(created_at, 'unixepoch', 'localtime') < '\(today)'
          AND date(created_at, 'unixepoch', 'localtime') >= '\(fromDay)'
        """
        // 历史聚合（早于本地已有明细最早一天的），展开成"每天每模型一行"的伪明细，
        // 请求侧无需再区分明细/聚合两套口径。created_at 取当天正午，保证 date() 落在原日期。
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
            CAST(strftime('%s', date || ' 12:00:00') AS INTEGER),
            request_count
        FROM \(alias).usage_daily_rollups
        WHERE date < (SELECT date(MIN(created_at), 'unixepoch', 'localtime')
                      FROM usage_log WHERE source = 'cc-switch')
        """
        return [detail, rollups]
    }

    func todayFragment(alias: String) -> String {
        return """
        SELECT 'cc-switch' AS source, app_type, model, input_tokens, output_tokens,
               cache_read_tokens, cache_creation_tokens, 0 AS reasoning_tokens,
               CAST(total_cost_usd AS REAL) AS total_cost_usd, created_at, 1 AS request_count
        FROM \(alias).proxy_request_logs
        WHERE date(created_at, 'unixepoch', 'localtime') = date('now', 'localtime')
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

    func syncSQLs(alias: String, fromDay: String, today: String) -> [String] {
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
          AND date(started_at / 1000, 'unixepoch', 'localtime') < '\(today)'
          AND date(started_at / 1000, 'unixepoch', 'localtime') >= '\(fromDay)'
        """
        return [detail]
    }

    func todayFragment(alias: String) -> String {
        return """
        SELECT 'zcode' AS source, 'zcode' AS app_type, model_id AS model,
               input_tokens, output_tokens,
               0 AS cache_read_tokens,
               0 AS cache_creation_tokens,
               reasoning_tokens, 0.0 AS total_cost_usd,
               started_at / 1000 AS created_at, 1 AS request_count
        FROM \(alias).model_usage
        WHERE status != 'running'
          AND date(started_at / 1000, 'unixepoch', 'localtime') = date('now', 'localtime')
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

final class StatsStore {
    private(set) var handle: OpaquePointer?
    private(set) var attachedAdapters: [SourceAdapter] = []

    static var storePath: String {
        let dir = "\(NSHomeDirectory())/Library/Application Support/ccbar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/ccbar.db"
    }

    /// 把 URI 里会破坏 file: 语法的字符转义
    private func uriEscape(_ path: String) -> String {
        return path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "?#").inverted) ?? path
    }

    // MARK: 基础执行

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db = handle else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func scalarInt(_ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard let db = handle, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    // MARK: 重建连接（启动、设置保存后调用）

    func rebuild(configs: [SourceConfig]) {
        close()

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        if sqlite3_open_v2(Self.storePath, &handle, flags, nil) != SQLITE_OK {
            print("[ccBar] 无法打开自建统计库: \(Self.storePath)")
            handle = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")

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

        // ATTACH 各启用且可用的源
        attachedAdapters.removeAll()
        for config in configs where config.enabled {
            guard let adapter = SourceRegistry.adapter(for: config.id) else { continue }
            if attach(adapter: adapter, path: config.dbPath) {
                attachedAdapters.append(adapter)
            }
        }

        rebuildView()
    }

    private func attach(adapter: SourceAdapter, path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            print("[ccBar] 数据源 \(adapter.name) 文件不存在，跳过: \(path)")
            return false
        }
        guard exec(adapter.attachSQL(fileURL: uriEscape(path))) else {
            print("[ccBar] 数据源 \(adapter.name) ATTACH 失败，跳过")
            return false
        }
        // 表都齐才算可用
        let list = adapter.requiredTables.joined(separator: "','")
        let found = scalarInt("SELECT COUNT(*) FROM \(adapter.alias).sqlite_master WHERE type='table' AND name IN ('\(list)')")
        if found < Int64(adapter.requiredTables.count) {
            print("[ccBar] 数据源 \(adapter.name) 缺少必需表，跳过")
            exec("DETACH DATABASE \(adapter.alias)")
            return false
        }
        return true
    }

    /// usage_all = 自家历史 + 各源今日实时。设置变化（启停/换路径）后重建。
    private func rebuildView() {
        exec("DROP VIEW IF EXISTS temp.usage_all")
        var parts = ["""
        SELECT source, app_type, model, input_tokens, output_tokens,
               cache_read_tokens, cache_creation_tokens, reasoning_tokens,
               total_cost_usd, created_at, request_count
        FROM usage_log
        """]
        for adapter in attachedAdapters {
            parts.append(adapter.todayFragment(alias: adapter.alias))
        }
        guard exec("CREATE TEMP VIEW usage_all AS " + parts.joined(separator: " UNION ALL ")) else {
            print("[ccBar] 创建 usage_all 视图失败")
            return
        }
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
    // 首次水位为空 → fromDay=1970，即全量回填。INSERT OR IGNORE 幂等。

    func syncIfNeeded() {
        guard !attachedAdapters.isEmpty else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }
        let yesterdayStr = fmt.string(from: yesterday)

        for adapter in attachedAdapters {
            let key = "synced_day_\(adapter.id)"
            let waterLine = metaGet(key)
            guard waterLine < yesterdayStr else { continue }   // 已是最新

            // 回看一天；首次全量
            var fromDay = "1970-01-01"
            if !waterLine.isEmpty, let d = fmt.date(from: waterLine),
               let back = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                fromDay = fmt.string(from: back)
            }

            for sql in adapter.syncSQLs(alias: adapter.alias, fromDay: fromDay, today: today) {
                if !exec(sql) {
                    print("[ccBar] \(adapter.name) 同步失败: \(sql.prefix(80))…")
                    return
                }
            }
            metaSet(key, value: yesterdayStr)
        }
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
}
