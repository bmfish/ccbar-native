import XCTest
@testable import CCBar

/// 签到引擎：请求头形态、派生确定性、灰度字段
final class TraeCheckinTests: XCTestCase {

    func testHeadersCarryFullClientShape() {
        let h = TraeCheckin.headers(jwt: "tok", uid: "942709926015804", deviceID: "450130483890571")
        XCTAssertEqual(h["authorization"], "Cloud-IDE-JWT tok")
        XCTAssertEqual(h["x-device-id"], "450130483890571")
        XCTAssertEqual(h["user-agent"], "VSCode 1.107.1 (TRAE SOLO CN)")
        XCTAssertEqual(h["x-lscbd-aid"], "787976")
        XCTAssertEqual(h["x-lscbd-platform"], "windows")
        XCTAssertEqual(h["package-type"], "stable_cn")
        XCTAssertEqual(h["x-lgw-req-sdk-type"], "3")
        XCTAssertEqual(h["app-version"], "0.1.45")
        XCTAssertEqual(h["x-user-region"], "CN")
    }

    func testMarketUserIDDeterministicPerUIDAndUUIDv4Shaped() {
        let a = TraeCheckin.headers(jwt: "t", uid: "942709926015804", deviceID: "d")
        let b = TraeCheckin.headers(jwt: "t", uid: "942709926015804", deviceID: "d")
        // 同账号恒定（跨启动稳定）
        XCTAssertEqual(a["x-market-user-id"], b["x-market-user-id"])
        // UUID v4 形态：8-4-4-4-12，版本位（m[6]，第 3 段首字符）= 4
        let groups = a["x-market-user-id"]!.split(separator: "-")
        XCTAssertEqual(groups.map(\.count), [8, 4, 4, 4, 12])
        XCTAssertEqual(groups[2].first, "4")
        // 变体位（m[8]，第 4 段首字符）∈ {8,9,a,b}
        XCTAssertTrue("89ab".contains(String(groups[3].first!)))
        // 不同账号派生不同
        let other = TraeCheckin.headers(jwt: "t", uid: "3172552512377002", deviceID: "d")
        XCTAssertNotEqual(a["x-market-user-id"], other["x-market-user-id"])
        // 会话 id 同样确定性（32 字节 → 64 hex）
        XCTAssertEqual(a["vscode-sessionid"]?.count, 64)
    }

    func testSlotMinuteDeterministicPerAccountAndDay() {
        let uid = "942709926015804"
        let m = TraeCheckin.slotMinute(uid: uid, day: "2026-11-13")
        // 同账号同日期恒定（跨启动/多轮同步不重掷）
        XCTAssertEqual(m, TraeCheckin.slotMinute(uid: uid, day: "2026-11-13"))
        XCTAssertTrue((0...59).contains(m))
        // 不同账号或不同日期派生不同分钟（避免所有账号同一分钟签到）
        let others = ["3172552512377002", "1870705802088522"].map {
            TraeCheckin.slotMinute(uid: $0, day: "2026-11-13")
        } + ["2026-11-14"].map { TraeCheckin.slotMinute(uid: uid, day: $0) }
        XCTAssertTrue(others.allSatisfy { (0...59).contains($0) })
        XCTAssertTrue(others.contains { $0 != m })
    }
}
