import Cocoa

// MARK: - Settings

/// 单个数据源的启用状态与库路径
struct SourceConfig: Codable {
    var id: String
    var enabled: Bool
    var dbPath: String

    static func defaults() -> [SourceConfig] {
        return [
            SourceConfig(id: "ccswitch", enabled: true,
                         dbPath: "\(NSHomeDirectory())/.cc-switch/cc-switch.db"),
            SourceConfig(id: "zcode", enabled: false,
                         dbPath: "\(NSHomeDirectory())/.zcode/cli/db/db.sqlite"),
        ]
    }
}

class Settings {
    let defaults = UserDefaults.standard

    var refreshInterval: Int {
        get { defaults.integer(forKey: "refreshInterval") == 0 ? 30 : defaults.integer(forKey: "refreshInterval") }
        set { defaults.set(newValue, forKey: "refreshInterval") }
    }

    /// 数据源列表。首次读取时迁移旧的单路径设置 dbPath 到 cc-switch 源。
    var sourceConfigs: [SourceConfig] {
        get {
            if let data = defaults.data(forKey: "sourceConfigs"),
               let arr = try? JSONDecoder().decode([SourceConfig].self, from: data) {
                return arr
            }
            var configs = SourceConfig.defaults()
            if let legacy = defaults.string(forKey: "dbPath"), !legacy.isEmpty,
               let idx = configs.firstIndex(where: { $0.id == "ccswitch" }) {
                configs[idx].dbPath = legacy
            }
            return configs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "sourceConfigs")
            }
        }
    }

    /// 供重置用的默认值
    func resetSourceConfigs() {
        sourceConfigs = SourceConfig.defaults()
    }

    var warningThreshold: Int {
        get { defaults.integer(forKey: "warningThreshold") == 0 ? 50 : defaults.integer(forKey: "warningThreshold") }
        set { defaults.set(newValue, forKey: "warningThreshold") }
    }

    var warningEnabled: Bool {
        get { defaults.object(forKey: "warningEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "warningEnabled") }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    /// 通知间隔（万），每累计到这个倍数弹一次通知，0=关闭
    var notifyInterval: Int {
        get {
            let v = defaults.integer(forKey: "notifyInterval")
            return v == 0 ? 1000 : v  // 默认1000万
        }
        set { defaults.set(newValue, forKey: "notifyInterval") }
    }
}

// MARK: - Data Cache

class DataCache {
    static let shared = DataCache()

    private var todayStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
    private var yesterdayStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
    private var weekStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
    private var monthStats: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?
    private var totalStats: (reqs: Int, total: Int64)?
    private var modelBreakdown: [(model: String, input: Int64, output: Int64, total: Int64)]?
    private var lastUpdate: Date = Date.distantPast
    private var lastDailyCacheDate: String?
    private var lastModelCacheDate: String?

    func getCachedToday() -> (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)? {
        return todayStats
    }

    func getCachedYesterday() -> (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)? {
        return yesterdayStats
    }

    func getCachedWeek() -> (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)? {
        return weekStats
    }

    func getCachedMonth() -> (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)? {
        return monthStats
    }

    func getCachedTotal() -> (reqs: Int, total: Int64)? {
        return totalStats
    }

    func getCachedModelBreakdown() -> [(model: String, input: Int64, output: Int64, total: Int64)]? {
        return modelBreakdown
    }

    func needsDailyCache() -> Bool {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        return lastDailyCacheDate != today
    }

    func needsModelCache() -> Bool {
        guard let lastDate = lastModelCacheDate else { return true }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        let currentHour = formatter.string(from: now)
        let lastHour = String(lastDate.prefix(2))
        return currentHour != lastHour
    }

    func update(
        today: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?,
        yesterday: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?,
        week: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?,
        month: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)?,
        total: (reqs: Int, total: Int64)?,
        models: [(model: String, input: Int64, output: Int64, total: Int64)]?
    ) {
        self.todayStats = today
        if yesterday != nil {
            self.yesterdayStats = yesterday
        }
        if week != nil {
            self.weekStats = week
        }
        if month != nil {
            self.monthStats = month
        }
        if total != nil {
            self.totalStats = total
        }
        if models != nil {
            self.modelBreakdown = models
        }
        self.lastUpdate = Date()
    }

    func markDailyCacheDone() {
        lastDailyCacheDate = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    }

    func markModelCacheDone() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        lastModelCacheDate = formatter.string(from: Date())
    }

    func getLastUpdateTime() -> Date {
        return lastUpdate
    }
}
