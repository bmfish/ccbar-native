import Foundation

// MARK: - Trae 数据源（HTTP）
//
// Trae 的用量不走本地 SQLite（本地 ai-agent 库是 SQLCipher 加密的），走官方网页端同一套 API：
//
//   passport sessionid（60 天）                         —— 用户唯一要提供的凭据
//    └→ POST /cloudide/api/v3/trae/Login                —— 换 X-Cloudide-Session（14 天，Set-Cookie 返回）
//        └→ POST /cloudide/api/v3/common/GetUserToken   —— 换 Cloud-IDE-JWT（8 小时，可无限续签）
//            ├→ POST /trae/api/v1/pay/query_user_usage_group_by_session   逐会话用量（token 四元组 + credits + 金额）
//            └→ POST /trae/api/v2/pay/ide_user_ent_usage                  积分总量/已用（官方账单口径）
//
// 全链路已抓包实测（2026-10），鉴权头只有 Authorization: Cloud-IDE-JWT，cookie 只在换签时用。
// usage_type=[7] 是 IDE 对话/Agent 消耗（1~8 里唯一有数据的类型，实测）。
// 口径：会话级聚合（跨零点会话计入 usage_time 那天）；amount/credits/cost 三者里
// credits 是积分消耗、cost_money_float 是折算金额。

// MARK: - API 端点与请求

enum TraeAPI {
    static let base = "https://api.trae.cn"
    static let loginPath = "/cloudide/api/v3/trae/Login"
    static let tokenPath = "/cloudide/api/v3/common/GetUserToken"
    static let usagePath = "/trae/api/v1/pay/query_user_usage_group_by_session"
    static let entUsagePath = "/trae/api/v2/pay/ide_user_ent_usage"

    /// 拉取窗口：首次 90 天全量回填，之后水位 - 2 天回看
    static let firstFetchDays = 90
    static let pageLookbackDays = 2
    /// 实测 page_size 上限 20（>20 报 9004 "The submitted order parameters are incorrect"），
    /// 与 trae.cn 网页端的默认值一致
    static let pageSize = 20
    static let maxPages = 50
}

// MARK: - 会话凭据状态（持久化在 meta 表，重启不丢）

struct TraeAuth: Codable, Equatable {
    var cloudideSession: String = ""   // X-Cloudide-Session 值（14 天）
    var jwt: String = ""               // Cloud-IDE-JWT（8 小时）
    var jwtExp: Int64 = 0              // JWT 过期时间（epoch 秒）
}

// MARK: - 归一化明细行（入库前）

struct TraeRow: Equatable {
    let sessionID: String
    let model: String
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let cacheWrite: Int64
    let costUsd: Double
    let credits: Double
    let epoch: Int64

    /// usage_log 幂等主键：会话是聚合原子单位，续拉同一会话 UPSERT 覆盖
    var requestID: String { "trae|" + sessionID }
}

// MARK: - 同步结果

enum TraeSyncOutcome: Equatable {
    case success(rows: [TraeRow], consumed: Double?, total: Double?)
    case notConfigured          // 未填 passport cookie
    case authExpired            // cookie 过期/无效，需要用户重新提供
    case failed(String)         // 网络或其他错误（附原因）

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - 响应模型（字段名与官方 JSON 一致）

struct TraeUsageResponse: Decodable {
    let code: Int?
    let total: Int?
    let user_usage_group_by_sessions: [TraeSession]?
}

struct TraeSession: Decodable {
    let session_id: String?
    let model_name: String?
    let usage_time: Int64?
    let amount_float: Double?
    let credits_float: Double?
    let cost_money_float: Double?
    let extra_info: TraeExtraInfo?
    let usage_group_details: [TraeGroupDetail]?
}

struct TraeExtraInfo: Decodable {
    let input_token: Int64?
    let output_token: Int64?
    let cache_read_token: Int64?
    let cache_write_token: Int64?
}

struct TraeGroupDetail: Decodable {
    let model_display_name: String?
    let credits_float: Double?
    let cost_money_float: Double?
}

struct TraeEntUsageResponse: Decodable {
    let code: Int?
    let usage_summary: TraeUsageSummary?
}

struct TraeUsageSummary: Decodable {
    let consumed_amount: Double?
    let total_amount: Double?
}

// MARK: - 同步引擎（纯函数式：网络 + 解析，不碰存储）

enum TraeSync {

    /// 完整同步一次。auth 由调用方加载/保存（StatsStore 持锁读写 meta）。
    /// fetchEnt=false 时跳过积分账单（它 1 小时刷一次就够，减少无谓请求）。
    static func run(passportCookie: String, auth: TraeAuth,
                    fromEpoch: Int64, toEpoch: Int64, fetchEnt: Bool = true) -> (outcome: TraeSyncOutcome, auth: TraeAuth) {
        var auth = auth
        guard !passportCookie.isEmpty else { return (.notConfigured, auth) }

        // ---- 1. 确保 JWT 可用（无效就换签）----
        let jwt: String
        switch ensureJWT(passportCookie: passportCookie, auth: &auth) {
        case .success(let token): jwt = token
        case .notConfigured: return (.notConfigured, auth)
        case .authExpired: return (.authExpired, auth)
        case .failed(let msg): return (.failed(msg), auth)
        }

        // ---- 2. 拉取会话明细（分页）----
        var rows: [TraeRow] = []
        var page = 1
        while page <= TraeAPI.maxPages {
            let body = "{\"start_time\":\(fromEpoch),\"end_time\":\(toEpoch)," +
                       "\"page_size\":\(TraeAPI.pageSize),\"page_num\":\(page),\"usage_type\":[7]}"
            let r = post(url: TraeAPI.base + TraeAPI.usagePath, auth: "Cloud-IDE-JWT \(jwt)", body: body)
            guard let data = r.data else { return (.failed(r.error ?? "无响应"), auth) }
            guard let resp = try? JSONDecoder().decode(TraeUsageResponse.self, from: data) else {
                return (.failed("响应解析失败"), auth)
            }
            // 错误码：1001 = 会话失效；9004 = 参数不合法（如 page_size 超限）；其余按服务端错误处理。
            // 成功响应没有 code 字段，不能把非 1001 的错误静默当成"空结果"
            if let code = resp.code {
                if code == 1001 { return (.authExpired, auth) }
                return (.failed("API code \(code)"), auth)
            }
            let sessions = resp.user_usage_group_by_sessions ?? []
            rows.append(contentsOf: sessions.compactMap(normalize))
            let total = resp.total ?? 0
            if rows.count >= total || sessions.isEmpty { break }
            page += 1
        }
        if page > TraeAPI.maxPages {
            print("[ccBar] Trae 分页达到上限 \(TraeAPI.maxPages)，本窗口可能不完整")
        }

        // ---- 3. 积分汇总（官方账单口径；失败不致命，按小时节流由调用方控制）----
        var consumed: Double?
        var total: Double?
        if fetchEnt {
            let entBody = "{\"require_usage\":true}"
            let ent = post(url: TraeAPI.base + TraeAPI.entUsagePath, auth: "Cloud-IDE-JWT \(jwt)", body: entBody)
            if let data = ent.data,
               let resp = try? JSONDecoder().decode(TraeEntUsageResponse.self, from: data),
               let s = resp.usage_summary {
                consumed = s.consumed_amount
                total = s.total_amount
            }
        }

        return (.success(rows: rows, consumed: consumed, total: total), auth)
    }

    // MARK: 换签链

    private enum JWTOutcome {
        case success(String)
        case notConfigured
        case authExpired
        case failed(String)
    }

    /// JWT 有效直接用；否则用 X-Cloudide-Session 换新；Session 也没有/失效就先 Login 再换。
    private static func ensureJWT(passportCookie: String, auth: inout TraeAuth) -> JWTOutcome {
        let now = Int64(Date().timeIntervalSince1970)
        if !auth.jwt.isEmpty, auth.jwtExp > now + 120, jwtLooksValid(auth.jwt) {
            return .success(auth.jwt)
        }

        // X-Cloudide-Session 换 JWT
        if !auth.cloudideSession.isEmpty {
            switch fetchToken(session: auth.cloudideSession) {
            case .success(let token, let exp):
                auth.jwt = token
                auth.jwtExp = exp
                return .success(token)
            case .authExpired:
                break   // Session 失效，走 Login 重造
            case .failed(let msg):
                return .failed(msg)
            case .notConfigured:
                return .notConfigured
            }
        }

        // Login：passport cookie → 新 X-Cloudide-Session → 再换 JWT
        guard let session = login(passportCookie: passportCookie) else {
            return .authExpired
        }
        auth.cloudideSession = session
        switch fetchToken(session: session) {
        case .success(let token, let exp):
            auth.jwt = token
            auth.jwtExp = exp
            return .success(token)
        case .authExpired, .notConfigured:
            return .authExpired
        case .failed(let msg):
            return .failed(msg)
        }
    }

    private enum TokenOutcome {
        case success(token: String, exp: Int64)
        case authExpired
        case failed(String)
        case notConfigured
    }

    private static func fetchToken(session: String) -> TokenOutcome {
        let cookie = "X-Cloudide-Session=\(session)"
        let r = post(url: TraeAPI.base + TraeAPI.tokenPath, cookie: cookie, body: "{}")
        guard let data = r.data else { return .failed(r.error ?? "无响应") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("GetUserToken 响应解析失败")
        }
        guard let result = obj["Result"] as? [String: Any],
              let token = result["Token"] as? String, !token.isEmpty else {
            // 1001 = 会话失效
            return .authExpired
        }
        return .success(token: token, exp: jwtExp(token))
    }

    /// Login 成功的标志：Set-Cookie 里出现新的 X-Cloudide-Session（有效期 14 天）
    private static func login(passportCookie: String) -> String? {
        let r = post(url: TraeAPI.base + TraeAPI.loginPath, cookie: passportCookie, body: "{}")
        guard r.http == 200, let headers = r.headers else { return nil }
        return extractSessionCookie(from: headers)
    }

    // MARK: 归一化

    /// 会话行 → 明细行。usage_group_details 只按模型细分 credits/金额、无 token 拆分，
    /// 所以整段会话一行入库，token 归到主模型（与 Trae 网页端展示口径一致）。
    static func normalize(_ s: TraeSession) -> TraeRow? {
        guard let sid = s.session_id, !sid.isEmpty,
              let epoch = s.usage_time, epoch > 0 else { return nil }
        let extra = s.extra_info
        return TraeRow(
            sessionID: sid,
            model: s.model_name ?? "unknown",
            input: extra?.input_token ?? 0,
            output: extra?.output_token ?? 0,
            cacheRead: extra?.cache_read_token ?? 0,
            cacheWrite: extra?.cache_write_token ?? 0,
            costUsd: s.cost_money_float ?? 0,
            credits: s.credits_float ?? s.amount_float ?? 0,
            epoch: epoch
        )
    }

    // MARK: 基础工具

    static func jwtLooksValid(_ token: String) -> Bool {
        token.split(separator: ".").count == 3
    }

    /// 解析 JWT payload 的 exp（epoch 秒），解析失败返回 0
    static func jwtExp(_ token: String) -> Int64 {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return 0 }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let num = obj["exp"] as? NSNumber else { return 0 }
        return num.int64Value
    }

    /// 从响应头提取 X-Cloudide-Session 的值（URLSession 会把多个 Set-Cookie 合并成一个逗号串）
    static func extractSessionCookie(from headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers {
            if (key as? String)?.lowercased() == "set-cookie",
               let merged = value as? String {
                for part in merged.components(separatedBy: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("X-Cloudide-Session=") {
                        let v = String(trimmed.dropFirst("X-Cloudide-Session=".count))
                        return String(v.prefix(while: { $0 != ";" }))
                    }
                }
            }
        }
        return nil
    }

    /// 同步 POST（信号量等待，调用方在后台串行队列）
    static func post(url: String, cookie: String? = nil, auth: String? = nil,
                     body: String, timeout: TimeInterval = 15) -> (data: Data?, http: Int?, headers: [AnyHashable: Any]?, error: String?) {
        guard let u = URL(string: url) else { return (nil, nil, nil, "URL 无效") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie = cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let auth = auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.httpBody = body.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var out: (Data?, Int?, [AnyHashable: Any]?, String?) = (nil, nil, nil, nil)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                out.3 = err.localizedDescription
            } else if let http = resp as? HTTPURLResponse {
                out.1 = http.statusCode
                out.0 = data
                out.2 = http.allHeaderFields
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return out
    }
}
