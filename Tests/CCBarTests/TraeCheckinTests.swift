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
}
