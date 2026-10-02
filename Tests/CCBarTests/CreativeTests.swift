import XCTest
@testable import CCBar

// MARK: - 创意套件（菜单栏伴侣 / 表情 / 成就）

final class CreativeTests: XCTestCase {
    func testFrameIntervalTiers() {
        XCTAssertNil(PetPose.frameInterval(progress: 0), "零用量睡觉，不动画")
        XCTAssertEqual(PetPose.frameInterval(progress: 0.1), 0.55)
        XCTAssertEqual(PetPose.frameInterval(progress: 0.5), 0.30)
        XCTAssertEqual(PetPose.frameInterval(progress: 0.9), 0.15)
    }

    func testEmojiTiers() {
        XCTAssertEqual(PetPose.emoji(progress: 0), "😴")
        XCTAssertEqual(PetPose.emoji(progress: 0.2), "🙂")
        XCTAssertEqual(PetPose.emoji(progress: 0.5), "😮\u{200D}💨")
        XCTAssertEqual(PetPose.emoji(progress: 0.9), "🥵")
        XCTAssertEqual(PetPose.emoji(progress: 1.2), "🤯")
    }

    func testStreak() {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 连续 7 天
        let consecutive = (0..<7).map { fmt.string(from: cal.date(byAdding: .day, value: -$0, to: today)!) }
        XCTAssertEqual(AchievementEngine.longestStreak(dates: consecutive), 7)

        // 断档：今天起 3 天 + 5 天前起 3 天 → 最长 3
        var gapped = (0..<3).map { fmt.string(from: cal.date(byAdding: .day, value: -$0, to: today)!) }
        gapped += (5..<8).map { fmt.string(from: cal.date(byAdding: .day, value: -$0, to: today)!) }
        XCTAssertEqual(AchievementEngine.longestStreak(dates: gapped), 3)

        XCTAssertNotNil(fmt.date(from: consecutive[0]))
    }

    func testNewlyEarned() {
        let facts = AchievementFacts(
            maxDayTokens: 120_000_000, weekendMaxTokens: 0,
            hasEarlyMorningRequest: true, activeDates: [],
            today: DayStats(reqs: 5, input: 500_000, output: 600_000, cacheCreate: 0, cacheRead: 0),
            totalTokens: 0)
        let newly = AchievementEngine.newlyEarned(facts: facts, earned: [])
        let ids = Set(newly.map { $0.id })
        XCTAssertTrue(ids.contains("hundred_million_day"))
        XCTAssertTrue(ids.contains("early_bird"))
        XCTAssertTrue(ids.contains("million_day"))
        XCTAssertFalse(ids.contains("weekend_warrior"), "周末数据不满足")
        XCTAssertFalse(ids.contains("cache_master"), "无缓存数据不满足")
        XCTAssertFalse(ids.contains("streak7"), "无活跃日期不满足")

        // 已解锁的不重复发放
        let again = AchievementEngine.newlyEarned(facts: facts, earned: Set(newly.map { $0.id }))
        XCTAssertTrue(again.isEmpty)
    }

    func testCacheMasterThreshold() {
        // 缓存命中率 90%+（input 10 + cacheRead 90 → 90%）
        let facts = AchievementFacts(
            maxDayTokens: 0, weekendMaxTokens: 0, hasEarlyMorningRequest: false, activeDates: [],
            today: DayStats(reqs: 3, input: 10, output: 5, cacheCreate: 0, cacheRead: 90),
            totalTokens: 0)
        let ids = Set(AchievementEngine.newlyEarned(facts: facts, earned: []).map { $0.id })
        XCTAssertTrue(ids.contains("cache_master"))
        // 命中率不足
        let low = AchievementFacts(
            maxDayTokens: 0, weekendMaxTokens: 0, hasEarlyMorningRequest: false, activeDates: [],
            today: DayStats(reqs: 3, input: 50, output: 5, cacheCreate: 0, cacheRead: 50),
            totalTokens: 0)
        XCTAssertFalse(AchievementEngine.newlyEarned(facts: low, earned: []).contains { $0.id == "cache_master" })
    }
}
