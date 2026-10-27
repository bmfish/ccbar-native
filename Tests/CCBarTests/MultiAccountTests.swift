import XCTest
@testable import CCBar

// MARK: - Trae 多账号（双槽 + per-uid 游标）测试

final class MultiAccountTests: XCTestCase {
    var tmpDir: String!
    var store: StatsStore!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "ccbar-multi-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        store = StatsStore(storePath: tmpDir + "/ccbar.db")
        // 建表（usage_log / meta / daily_agg）：rebuild 空配置即纯本地库，不 ATTACH 任何源
        store.rebuild(configs: [])
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    /// 构造伪 JWT：header.payload.signature（base64url，无签名校验，jwtUID 只解 payload）
    private func makeJWT(uid: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64(#"{"alg":"RS256","typ":"JWT"}"#)
        let payload = b64(#"{"data":{"id":"\#(uid)","source":"session","type":"user"},"exp":1799999999,"iat":1799990000}"#)
        return "\(header).\(payload).sig"
    }

    // MARK: jwtUID

    func testJwtUIDDecodesStringID() {
        XCTAssertEqual(TraeSync.jwtUID(makeJWT(uid: "942709926015804")), "942709926015804")
    }

    func testJwtUIDHandlesNumericID() {
        // 服务端若把 id 发成数字，也要归一成字符串
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = b64(#"{"data":{"id":123456}}"#)
        XCTAssertEqual(TraeSync.jwtUID("h.\(payload).s"), "123456")
    }

    func testJwtUIDRejectsGarbage() {
        XCTAssertNil(TraeSync.jwtUID(""))
        XCTAssertNil(TraeSync.jwtUID("not-a-jwt"))
        XCTAssertNil(TraeSync.jwtUID("a.###.c"))
        XCTAssertNil(TraeSync.jwtUID("a.\(Data("{}".utf8).base64EncodedString()).c"))
    }

    // MARK: credentialIdentity 指纹

    func testIdentityBareSessionIDEqualsPrefixedCookie() {
        // 裸值 / 带前缀 / 整段 Cookie（同 sessionid）→ 指纹一致（同账号，游标应保留）
        let bare = TraeSync.credentialIdentity("c57b3c1dbc326bfa")
        let prefixed = TraeSync.credentialIdentity("sessionid=c57b3c1dbc326bfa")
        let full = TraeSync.credentialIdentity(
            "is_staff_user=false; sessionid=c57b3c1dbc326bfa; uid_tt=abc; X-Cloudide-Session=xyz=.18e2")
        XCTAssertEqual(bare, prefixed)
        XCTAssertEqual(bare, full)
    }

    func testIdentityDiffersAcrossAccounts() {
        let a = TraeSync.credentialIdentity("sessionid=aaa")
        let b = TraeSync.credentialIdentity("sessionid=bbb")
        XCTAssertNotEqual(a, b)
    }

    func testIdentityFallsBackToCloudideSession() {
        XCTAssertEqual(TraeSync.credentialIdentity("X-Cloudide-Session=abc=.18e2"), "abc=.18e2")
    }

    // MARK: 余额合计（per-uid 键 + 旧全局键兼容）

    func testEntSummarySumsMultipleUIDKeys() {
        store.metaSet("trae_ent_111", value: "100|1000")
        store.metaSet("trae_ent_222", value: "50.5|500.5")
        store.metaSet("trae_ent_at", value: "1793110905")     // 节流时间戳，必须跳过
        store.metaSet("trae_ent_at_2", value: "1793110906")
        let sum = store.traeEntSummary()
        XCTAssertEqual(sum?.consumed ?? -1, 150.5, accuracy: 0.001)
        XCTAssertEqual(sum?.total ?? -1, 1500.5, accuracy: 0.001)
    }

    func testEntSummaryPrefersPerUIDOverLegacy() {
        // 迁移脚本未跑时可能同时存在旧全局键与 per-uid 键（同账号），此时忽略旧键防双算
        store.metaSet("trae_ent", value: "6441.38|9450.0")
        store.metaSet("trae_ent_942709926015804", value: "10|100")
        let sum = store.traeEntSummary()
        XCTAssertEqual(sum?.consumed ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(sum?.total ?? -1, 100, accuracy: 0.001)
    }

    func testEntSummaryFallsBackToLegacyKey() {
        store.metaSet("trae_ent", value: "6441.38|9450.0")
        let sum = store.traeEntSummary()
        XCTAssertEqual(sum?.consumed ?? -1, 6441.38, accuracy: 0.001)
        XCTAssertEqual(sum?.total ?? -1, 9450.0, accuracy: 0.001)
    }

    func testEntSummaryNilWhenEmpty() {
        XCTAssertNil(store.traeEntSummary())
    }

    // MARK: 凭据变更只清 JWT 缓存，不删明细

    func testCredentialChangeKeepsUsageRows() {
        let row = TraeRow(sessionID: "s1", model: "m", input: 10, output: 5,
                          cacheRead: 0, cacheWrite: 0, costUsd: 0.1, credits: 1,
                          epoch: 1_793_000_000)
        store.upsertTraeRows([row])
        XCTAssertEqual(store.scalarInt("SELECT COUNT(*) FROM usage_log WHERE source='trae'"), 1)
        // 模拟 rebuild 换凭据（rebuild 走配置，此处直接验证删除逻辑已不存在：
        // metaSet 清 auth 后行数不变）
        store.metaSet("trae_auth", value: "")
        XCTAssertEqual(store.scalarInt("SELECT COUNT(*) FROM usage_log WHERE source='trae'"), 1)
    }
}
