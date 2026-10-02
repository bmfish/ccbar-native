import Cocoa
import ServiceManagement

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

    /// 菜单栏动画伴侣（小猫随用量跑动）
    var menuPetEnabled: Bool {
        get { defaults.object(forKey: "menuPetEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "menuPetEnabled") }
    }

    /// 菜单栏表情分级（🙂→🥵）
    var menuEmojiEnabled: Bool {
        get { defaults.object(forKey: "menuEmojiEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "menuEmojiEnabled") }
    }

    /// 宽版弹窗
    var popoverWide: Bool {
        get { defaults.bool(forKey: "popoverWide") }
        set { defaults.set(newValue, forKey: "popoverWide") }
    }

    /// 闪电 LED 红色门槛（万）：单次刷新增量达到即变红，0 = 不变红
    var ledRedThreshold: Int {
        get { defaults.object(forKey: "ledRedThreshold") == nil ? 100 : defaults.integer(forKey: "ledRedThreshold") }
        set { defaults.set(newValue, forKey: "ledRedThreshold") }
    }

    /// 开机启动：除记录偏好外，真正注册/注销系统登录项（SMAppService，macOS 13+）
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        guard #available(macOS 13.0, *) else {
            print("[ccBar] 开机启动需要 macOS 13+，仅记录偏好")
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("[ccBar] 开机启动设置失败: \(error.localizedDescription)")
        }
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
//
// 定时器在后台队列查询、写入缓存；UI 在主线程读缓存。全部访问经锁串行。

final class DataCache {
    static let shared = DataCache()
    private let lock = NSLock()

    private var todayStats: DayStats?
    private var yesterdayStats: DayStats?
    private var weekStats: DayStats?
    private var monthStats: DayStats?
    private var totalStats: TotalStats?
    private var modelBreakdown: [ModelStat]?
    private var workHours: Double?
    private var lastDailyCacheDate: String?
    private var lastModelCacheHour = -1

    func getCachedToday() -> DayStats? {
        lock.lock(); defer { lock.unlock() }
        return todayStats
    }

    func getCachedYesterday() -> DayStats? {
        lock.lock(); defer { lock.unlock() }
        return yesterdayStats
    }

    func getCachedWeek() -> DayStats? {
        lock.lock(); defer { lock.unlock() }
        return weekStats
    }

    func getCachedMonth() -> DayStats? {
        lock.lock(); defer { lock.unlock() }
        return monthStats
    }

    func getCachedTotal() -> TotalStats? {
        lock.lock(); defer { lock.unlock() }
        return totalStats
    }

    func getCachedModelBreakdown() -> [ModelStat]? {
        lock.lock(); defer { lock.unlock() }
        return modelBreakdown
    }

    func getCachedWorkHours() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return workHours
    }

    /// 历史区间（昨日/周/月/总量）每天重查一次
    func needsDailyCache() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        return lastDailyCacheDate != today
    }

    /// 模型分布每小时重查一次
    func needsModelCache() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Calendar.current.component(.hour, from: Date()) != lastModelCacheHour
    }

    func update(
        today: DayStats?,
        yesterday: DayStats?,
        week: DayStats?,
        month: DayStats?,
        total: TotalStats?,
        models: [ModelStat]?,
        workHours: Double?
    ) {
        lock.lock(); defer { lock.unlock() }
        self.todayStats = today
        if let v = yesterday { self.yesterdayStats = v }
        if let v = week { self.weekStats = v }
        if let v = month { self.monthStats = v }
        if let v = total { self.totalStats = v }
        if let v = models { self.modelBreakdown = v }
        if let v = workHours { self.workHours = v }
    }

    func markDailyCacheDone() {
        lock.lock(); defer { lock.unlock() }
        lastDailyCacheDate = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    }

    func markModelCacheDone() {
        lock.lock(); defer { lock.unlock() }
        lastModelCacheHour = Calendar.current.component(.hour, from: Date())
    }

    /// 仅供测试：清空单例状态
    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        todayStats = nil
        yesterdayStats = nil
        weekStats = nil
        monthStats = nil
        totalStats = nil
        modelBreakdown = nil
        workHours = nil
        lastDailyCacheDate = nil
        lastModelCacheHour = -1
    }
}
