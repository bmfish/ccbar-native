import Cocoa

// MARK: - 成就徽章系统
//
// 徽章从 daily_agg / usage_log 派生，解锁一次永久保存（UserDefaults）。
// 每日历史缓存刷新时评估一次，新解锁走系统通知 + 弹窗成就卡展示。

struct Achievement: Equatable {
    let id: String
    let emoji: String
    let title: String
    let desc: String
}

/// 派生成就所需的原始事实（由 StatsStore 一次性查好，评估保持纯函数）
struct AchievementFacts: Equatable {
    var maxDayTokens: Int64          // 历史最大单日 token
    var weekendMaxTokens: Int64      // 历史最大周末单日 token
    var hasEarlyMorningRequest: Bool // 凌晨 0-5 点出过请求
    var activeDates: [String]        // 有用量的日期（yyyy-MM-dd，升序）
    var today: DayStats?
    var totalTokens: Int64           // 历史总量
}

enum AchievementCatalog {
    static let all: [Achievement] = [
        Achievement(id: "early_bird", emoji: "🌙", title: "凌晨四点的洛杉矶",
                    desc: "凌晨 0-5 点还在出请求"),
        Achievement(id: "hundred_million_day", emoji: "💯", title: "单日亿级选手",
                    desc: "单日用量突破 1 亿 token"),
        Achievement(id: "streak7", emoji: "🔥", title: "七连肝",
                    desc: "连续 7 天都有用量记录"),
        Achievement(id: "weekend_warrior", emoji: "🎰", title: "周末肝王",
                    desc: "周末单日突破 5000 万 token"),
        Achievement(id: "cache_master", emoji: "🧮", title: "缓存精算师",
                    desc: "当日缓存命中率 ≥ 90%（需要 cc-switch 数据源）"),
        Achievement(id: "million_day", emoji: "🚀", title: "今日破百万",
                    desc: "单日用量突破 100 万 token"),
    ]

    static func achievement(id: String) -> Achievement? {
        all.first { $0.id == id }
    }
}

enum AchievementEngine {
    /// 评估当前满足但尚未解锁的成就
    static func newlyEarned(facts: AchievementFacts, earned: Set<String>) -> [Achievement] {
        var satisfied = Set<String>()

        if facts.hasEarlyMorningRequest { satisfied.insert("early_bird") }
        if facts.maxDayTokens >= 100_000_000 { satisfied.insert("hundred_million_day") }
        if facts.weekendMaxTokens >= 50_000_000 { satisfied.insert("weekend_warrior") }
        if longestStreak(dates: facts.activeDates) >= 7 { satisfied.insert("streak7") }
        if let today = facts.today, today.total >= 1_000_000 { satisfied.insert("million_day") }
        if let today = facts.today {
            let denom = today.input + today.cacheRead
            if denom > 0 && Double(today.cacheRead) / Double(denom) >= 0.9 {
                satisfied.insert("cache_master")
            }
        }

        return AchievementCatalog.all.filter { satisfied.contains($0.id) && !earned.contains($0.id) }
    }

    /// 含今天的连续活跃天数（允许最后一天断在昨天：今天还没用量不算断签）
    static func longestStreak(dates: [String]) -> Int {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let set = Set(dates.compactMap { fmt.date(from: $0) })
        guard !set.isEmpty else { return 0 }

        var best = 0
        for start in set {
            // 只从"前一天不活跃"的日期起算，避免重复计段
            guard cal.date(byAdding: .day, value: -1, to: start).map({ !set.contains($0) }) ?? true else { continue }
            var length = 1
            while let next = cal.date(byAdding: .day, value: length, to: start), set.contains(next) {
                length += 1
            }
            best = max(best, length)
        }
        return best
    }
}

/// 解锁记录持久化
enum AchievementStore {
    private static let key = "earnedAchievements"

    static var earned: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func earn(_ achievement: Achievement) {
        var ids = earned
        guard !ids.contains(achievement.id) else { return }
        ids.insert(achievement.id)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}
