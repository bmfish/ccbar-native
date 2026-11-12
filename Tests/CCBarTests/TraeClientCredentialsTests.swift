import XCTest
import CryptoKit
import CommonCrypto
@testable import CCBar

/// 客户端凭据通道：tc 信封解密、JWT 解析、双客户端发现、DeviceProof 签名原文
final class TraeClientCredentialsTests: XCTestCase {

    // MARK: 测试用 tc 信封加密（与实现互逆，验证解密正确性）

    private static func sha512(_ data: Data) -> Data {
        CryptoKit.SHA512.hash(data: data).withUnsafeBytes { Data($0) }
    }

    private static func aesCBCCrypt(key: [UInt8], iv: [UInt8], data: [UInt8],
                                    encrypt: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                             CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, data, data.count, &out, out.count, &outLen)
        XCTAssertEqual(Int(status), kCCSuccess)
        return Array(out[0..<outLen])
    }

    /// 按客户端 byteCrypto 的封装格式造一个合法信封
    private static func tcEncrypt(_ plaintext: String) -> String {
        let random = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let pepper = zip(TraeClientCredentials.woeT, TraeClientCredentials.voeT).map { $0 ^ $1 }
        let h1 = sha512(Data(random) + Data(pepper))
        let c = sha512(h1 + Data(pepper))
        let key = Array(c[0..<16]), iv = Array(c[16..<32])
        let body = Array(plaintext.utf8)
        let tag = Array(sha512(Data(body)))
        let padded = aesCBCCrypt(key: key, iv: iv, data: tag + body, encrypt: true)
        let envelope = TraeClientCredentials.envelopeHeader + random + padded
        return Data(envelope).base64EncodedString()
    }

    private static func makeJWT(uid: String, exp: Int64) -> String {
        let header = Data("{\"alg\":\"RS256\",\"typ\":\"JWT\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payloadJSON = "{\"data\":{\"id\":\"\(uid)\"},\"exp\":\(exp)}"
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }

    private static func makeStorageJSON(jwt: String, rt: String, refreshExpMs: Double) throws -> String {
        let key = P256.Signing.PrivateKey()
        let cloudide: [String: Any] = [
            "token": jwt, "refreshToken": rt, "refreshExpiredAt": refreshExpMs,
        ]
        let device: [String: Any] = ["privateKeyPEM": key.pemRepresentation]
        let obj: [String: Any] = [
            "iCubeAuthInfo://icube.cloudide": tcEncrypt(String(data: try JSONSerialization.data(withJSONObject: cloudide), encoding: .utf8)!),
            "iCubeAuthInfo://icube-dc:450130483890571": tcEncrypt(String(data: try JSONSerialization.data(withJSONObject: device), encoding: .utf8)!),
            "telemetry.machineId": "0123456789abcdef0123456789abcdef",
        ]
        return String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    override func tearDown() {
        TraeClientCredentials.storageOverride = nil
        super.tearDown()
    }

    // MARK: 解密

    func testTCDecryptRoundtrip() throws {
        let plain = #"{"token":"abc","refreshToken":"rt","nested":{"k":1}}"#
        let envelope = Self.tcEncrypt(plain)
        XCTAssertEqual(try TraeClientCredentials.tcDecrypt(envelope), plain)
    }

    func testTCDecryptRejectsCorruption() {
        let envelope = Self.tcEncrypt("hello")
        // 篡改密文尾部 → SHA512 完整性校验失败
        var bytes = Array(Data(base64Encoded: envelope)!)
        bytes[bytes.count - 1] ^= 0xFF
        XCTAssertThrowsError(try TraeClientCredentials.tcDecrypt(Data(bytes).base64EncodedString()))
        // 非 base64
        XCTAssertThrowsError(try TraeClientCredentials.tcDecrypt("!!!not-base64!!!"))
    }

    // MARK: JWT 解析

    func testParseJWTPayload() {
        let jwt = Self.makeJWT(uid: "942709926015804", exp: 1_799_999_999)
        let parsed = TraeClientCredentials.parseJWTPayload(jwt)
        XCTAssertEqual(parsed?.uid, "942709926015804")
        XCTAssertEqual(parsed?.exp, 1_799_999_999)
        XCTAssertNil(TraeClientCredentials.parseJWTPayload("not-a-jwt"))
    }

    // MARK: 双客户端发现（uid 去重 + 设备私钥提取）

    func testDiscoverDedupesByUIDAndKeepsFreshest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbar-client-cred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let uid = "942709926015804"
        let app1 = dir.appendingPathComponent("Trae CN/User/globalStorage/storage.json")
        let app2 = dir.appendingPathComponent("Trae CN 2/User/globalStorage/storage.json")
        try FileManager.default.createDirectory(at: app1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app2.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 同账号两份凭据：app2 的 JWT 更新 → 应保留 app2
        try Self.makeStorageJSON(jwt: Self.makeJWT(uid: uid, exp: 1_000_000), rt: "rt-old", refreshExpMs: 9_000_000_000)
            .write(to: app1, atomically: true, encoding: .utf8)
        try Self.makeStorageJSON(jwt: Self.makeJWT(uid: uid, exp: 2_000_000), rt: "rt-new", refreshExpMs: 9_000_000_000)
            .write(to: app2, atomically: true, encoding: .utf8)
        TraeClientCredentials.storageOverride = [app1, app2]

        let accounts = TraeClientCredentials.discover()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.uid, uid)
        XCTAssertEqual(accounts.first?.jwtExp, 2_000_000)
        XCTAssertEqual(accounts.first?.refreshToken, "rt-new")
        XCTAssertEqual(accounts.first?.deviceID, "450130483890571")
        XCTAssertTrue(accounts.first?.deviceKeyPEM.contains("BEGIN") == true)
    }

    func testDiscoverIgnoresMissingOrMalformedStorage() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).json")
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
        try "{not json".write(to: bad, atomically: true, encoding: .utf8)
        TraeClientCredentials.storageOverride = [missing, bad]
        XCTAssertTrue(TraeClientCredentials.discover().isEmpty)
    }

    // MARK: DeviceProof 签名原文（对齐客户端 main.js 逆向口径）

    func testProofMessageFormat() {
        let msg = TraeClientCredentials.proofMessage(
            signPath: "/trae/api/v3/oauth/ExchangeToken", clientID: "ono9krqynydwx5",
            token: "rt-token", ts: 1_700_000_000, nonce: "abcd")
        XCTAssertEqual(msg, "POST\n/trae/api/v3/oauth/ExchangeToken\nono9krqynydwx5\nrt-token\n1700000000\nabcd")
    }

    func testNonceIsUniqueHex32() {
        let a = TraeClientCredentials.nonce()
        let b = TraeClientCredentials.nonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }

    // MARK: 续签跳过条件（无 RT / 无设备私钥 / 无设备号时不开网络）

    func testRefreshRequiresFullIngredients() {
        let base = ClientTraeAccount(uid: "1", jwt: Self.makeJWT(uid: "1", exp: 0), jwtExp: 0,
                                     refreshToken: "", refreshExp: 0,
                                     deviceID: "", deviceKeyPEM: "", sourceApp: "test")
        XCTAssertNil(TraeClientCredentials.refresh(account: base))
    }
}
