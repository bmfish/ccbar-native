import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Trae 客户端凭据通道（零配置自动发现）
//
// 背景（2026-11 实证）：sessionid→Login 链造出的 JWT 鉴权等级不够，被签到网关拒绝；
// 只有 Trae 客户端自动续签的 refresh_token 源 JWT 能通过全部业务接口。
// 客户端把当前账号的 JWT/RT 存在 storage.json 的 tc 信封里，设备 EC P-256 私钥也存在——
// 三个原料本机齐全，ccBar 直接读取即可获得"客户端即续签机"的免配置体验：
//
//   ~/Library/Application Support/Trae {CN, CN 2}/User/globalStorage/storage.json
//     ├─ iCubeAuthInfo://icube.cloudide   → {token, refreshToken, expiredAt, refreshExpiredAt, userId}
//     ├─ iCubeAuthInfo://icube-dc:<devId> → {privateKeyPEM}（RT 续签 DeviceProof 签名用）
//     └─ telemetry.machineId
//
// 红线：只读本机自有客户端存储；JWT/RT/私钥不落日志、不进事件。

// MARK: - 客户端账号

struct ClientTraeAccount: Equatable {
    let uid: String
    let jwt: String
    let jwtExp: Int64
    let refreshToken: String
    let refreshExp: Int64
    let deviceID: String
    /// PKCS8 PEM（icube-dc 键解密所得；缺失 = 本机客户端版本不认）
    let deviceKeyPEM: String
    let sourceApp: String
}

// MARK: - 发现与续签

enum TraeClientCredentials {

    static let exchangeURL = "https://api.trae.com.cn/trae/api/v3/oauth/ExchangeToken"
    static let exchangeSignPath = "/trae/api/v3/oauth/ExchangeToken"
    static let clientID = "ono9krqynydwx5"

    /// 测试注入：覆盖真实客户端存储路径
    nonisolated(unsafe) static var storageOverride: [URL]?

    /// 双客户端存储路径（容器外的普通应用支持目录；Trae 非沙盒）
    static var storageURLs: [URL] {
        if let storageOverride { return storageOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["Trae CN", "Trae CN 2"].map {
            support.appendingPathComponent("\($0)/User/globalStorage/storage.json")
        }
    }

    /// 扫描双客户端，按 uid 去重（同一账号在两个客户端都活跃时只留一份）
    static func discover(now: Date = Date()) -> [ClientTraeAccount] {
        var byUID: [String: ClientTraeAccount] = [:]
        for url in storageURLs {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let app = url.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            guard let cloudide = cloudideEntry(in: obj) else { continue }
            let device = deviceEntry(in: obj)
            let jwt = cloudide.token
            guard jwt.hasPrefix("eyJ"), let payload = parseJWTPayload(jwt), !payload.uid.isEmpty else { continue }
            let account = ClientTraeAccount(
                uid: payload.uid,
                jwt: jwt,
                jwtExp: payload.exp,
                refreshToken: cloudide.refreshToken,
                refreshExp: Int64((cloudide.refreshExpiredAt ?? 0) / 1000),
                deviceID: device?.deviceID ?? "",
                deviceKeyPEM: device?.privateKeyPEM ?? "",
                sourceApp: app)
            if let old = byUID[account.uid], old.jwtExp >= account.jwtExp { continue }
            byUID[account.uid] = account
        }
        return byUID.values.sorted { $0.uid < $1.uid }
    }

    // MARK: JWT 解析

    /// JWT payload → (uid, exp)。解析失败返回 nil（签名/格式不校验，调用方以业务码为准）
    static func parseJWTPayload(_ token: String) -> (uid: String, exp: Int64)? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dataObj = obj["data"] as? [String: Any]
        let uid = (dataObj?["id"] as? String) ?? (obj["uid"] as? String) ?? ""
        let exp = (obj["exp"] as? Double).map { Int64($0) } ?? (obj["exp"] as? Int64) ?? 0
        return (uid, exp)
    }

    // MARK: RT 续签（兜底：客户端超 ~12 天没启动时自救）

    /// DeviceProof 签名原文（对齐 Trae 客户端 main.js 逆向：5 个 \n 连接）
    static func proofMessage(signPath: String, clientID: String, token: String,
                             ts: Int64, nonce: String) -> String {
        "POST\n\(signPath)\n\(clientID)\n\(token)\n\(ts)\n\(nonce)"
    }

    struct RefreshedToken {
        let jwt: String
        let jwtExp: Int64
        let refreshToken: String?      // 服务端可能轮换；nil = 沿用旧 RT
        let refreshExp: Int64?
    }

    /// 用 RT + 设备私钥换新 JWT。仅设备私钥可用且未失效时才可能成功。
    static func refresh(account: ClientTraeAccount, now: Date = Date()) -> RefreshedToken? {
        guard !account.refreshToken.isEmpty, !account.deviceKeyPEM.isEmpty,
              !account.deviceID.isEmpty else { return nil }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: account.deviceKeyPEM) else { return nil }
        let ts = Int64(now.timeIntervalSince1970)
        let nonce = Self.nonce()
        let msg = proofMessage(signPath: exchangeSignPath, clientID: clientID,
                               token: account.refreshToken, ts: ts, nonce: nonce)
        guard let sig = try? key.signature(for: Data(msg.utf8)) else { return nil }
        let sigB64 = sig.rawRepresentation.base64EncodedString()
        let body: [String: Any] = [
            "ClientID": clientID,
            "RefreshToken": account.refreshToken,
            "DeviceID": account.deviceID,
            "PlatformCode": "IDE_PC",
            "DeviceProof": ["Signature": sigB64, "Timestamp": ts, "Nonce": nonce],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: URL(string: exchangeURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = payload
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(account.deviceID, forHTTPHeaderField: "x-device-id")
        req.setValue("6eefa01c-1036-4c7e-9ca5-d891f63bfcd8", forHTTPHeaderField: "x-app-id")
        req.setValue("IDE_PC", forHTTPHeaderField: "x-platform-code")
        req.setValue("", forHTTPHeaderField: "x-cloudide-token")
        guard let (data, resp) = try? URLSession.shared.syncData(with: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["Result"] as? [String: Any],
              let jwt = result["Token"] as? String, jwt.hasPrefix("eyJ"),
              let parsed = parseJWTPayload(jwt) else { return nil }
        let rotatedRT = result["RefreshToken"] as? String
        return RefreshedToken(jwt: jwt, jwtExp: parsed.exp,
                              refreshToken: (rotatedRT?.isEmpty == false) ? rotatedRT : nil,
                              refreshExp: nil)
    }

    /// 32 位随机 hex nonce
    static func nonce() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: storage.json 解析

    private struct CloudideEntry {
        let token: String
        let refreshToken: String
        let refreshExpiredAt: Double?
    }

    private struct DeviceEntry {
        let deviceID: String
        let privateKeyPEM: String
    }

    /// icube.cloudide 键解密（活跃账号 JWT/RT）
    private static func cloudideEntry(in obj: [String: Any]) -> CloudideEntry? {
        guard let b64 = obj["iCubeAuthInfo://icube.cloudide"] as? String,
              let plain = try? tcDecrypt(b64),
              let entry = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
              let token = entry["token"] as? String else { return nil }
        return CloudideEntry(token: token,
                             refreshToken: entry["refreshToken"] as? String ?? "",
                             refreshExpiredAt: entry["refreshExpiredAt"] as? Double)
    }

    /// icube-dc 键解密（设备 EC 私钥；可能多把，返回第一把能解析的）
    private static func deviceEntry(in obj: [String: Any]) -> DeviceEntry? {
        for (key, value) in obj {
            guard key.hasPrefix("iCubeAuthInfo://icube-dc:") else { continue }
            let deviceID = String(key.dropFirst("iCubeAuthInfo://icube-dc:".count))
            guard !deviceID.isEmpty, deviceID.allSatisfy(\.isNumber),
                  let b64 = value as? String,
                  let plain = try? tcDecrypt(b64),
                  let entry = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
                  let pem = entry["privateKeyPEM"] as? String, pem.contains("BEGIN") else { continue }
            return DeviceEntry(deviceID: deviceID, privateKeyPEM: pem)
        }
        return nil
    }

    // MARK: tc 信封解密（复刻客户端 byteCrypto：公开 pepper 常量表 + AES-128-CBC + SHA512 校验）

    static let woeT: [UInt8] = [82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37]
    static let voeT: [UInt8] = [31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125]
    static let envelopeHeader: [UInt8] = [116, 99, 5, 16, 0, 0]
    static let sha512Length = 64

    /// tc 信封 → 明文。magic/长度/SHA512 完整性任一不符即抛错。
    static func tcDecrypt(_ b64: String) throws -> String {
        guard let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DecryptionError("base64 解码失败")
        }
        let bytes = [UInt8](raw)
        guard bytes.count > envelopeHeader.count + 32 + sha512Length else {
            throw DecryptionError("信封长度异常: \(bytes.count)")
        }
        guard Array(bytes[0..<6]) == envelopeHeader else {
            throw DecryptionError("magic 不匹配")
        }
        let random = Array(bytes[6..<38])
        let cipher = Array(bytes[38...])
        let pepper = zip(woeT, voeT).map { $0 ^ $1 }
        // deriveKeys：n = SHA512(random) || pepper → c = SHA512(n) → 前 32B 切 key/iv
        let h1 = Self.sha512(Data(random))
        let c = Self.sha512(h1 + Data(pepper))
        let key = Array(c[0..<16]), iv = Array(c[16..<32])
        let padded = try Self.aesCBCDecrypt(key: key, iv: iv, data: cipher)
        guard padded.count > sha512Length else { throw DecryptionError("明文过短") }
        let tag = Array(padded[0..<sha512Length])
        let plain = Array(padded[sha512Length...])
        guard Array(Self.sha512(Data(plain))) == tag else { throw DecryptionError("完整性校验失败") }
        guard let text = String(data: Data(plain), encoding: .utf8) else {
            throw DecryptionError("明文非 UTF-8")
        }
        return text
    }

    struct DecryptionError: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }

    static func sha512(_ data: Data) -> Data {
        CryptoKit.SHA512.hash(data: data).withUnsafeBytes { Data($0) }
    }

    /// AES-128-CBC + PKCS7（CommonCrypto CCCrypt）
    static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw DecryptionError("key/iv 长度错误")
        }
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, data, data.count, &out, out.count, &outLen)
        guard status == kCCSuccess else { throw DecryptionError("AES 解密失败 status=\(status)") }
        return Array(out[0..<outLen])
    }
}

// MARK: - URLSession 同步扩展（同步链路里最省事；调用方都在后台队列）

extension URLSession {
    func syncData(with request: URLRequest) throws -> (Data, URLResponse?) {
        var result: Result<(Data, URLResponse?), Error>!
        let semaphore = DispatchSemaphore(value: 0)
        dataTask(with: request) { data, resp, err in
            if let err { result = .failure(err) }
            else { result = .success((data ?? Data(), resp)) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
