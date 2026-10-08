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
    static let checkinStatusPath = "/trae/api/v2/ug/checkin_credits/status"
    static let checkinClaimPath = "/trae/api/v2/ug/checkin_credits/claim"

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

/// 签到 status/claim 共用的响应结构（官方 JSON 字段名）
struct TraeCheckinResponse: Decodable {
    let code: Int?
    let message: String?
    let enable: Bool?
    let checked_in: Bool?
    let credits: Double?
    let extra_credits: Double?
}

// MARK: - 每日签到（100 积分 + 会员加成）

// MARK: - 同步引擎（纯函数式：网络 + 解析，不碰存储）

enum TraeSync {

    /// 完整同步一次。auth 由调用方加载/保存（StatsStore 持锁读写 meta）。
    /// fetchEnt=false 时跳过积分账单（它 1 小时刷一次就够，减少无谓请求）。
    static func run(passportCookie: String, auth: TraeAuth,
                    fromEpoch: Int64, toEpoch: Int64, fetchEnt: Bool = true) -> (outcome: TraeSyncOutcome, auth: TraeAuth) {
        var auth = auth
        guard !passportCookie.isEmpty else { return (.notConfigured, auth) }

        // ---- 1. 确保 JWT 可用（无效就换签）----
        var jwt: String
        switch ensureJWT(passportCookie: passportCookie, auth: &auth) {
        case .success(let token): jwt = token
        case .notConfigured: return (.notConfigured, auth)
        case .authExpired: return (.authExpired, auth)
        case .failed(let msg): return (.failed(msg), auth)
        }

        // ---- 2. 拉取会话明细（分页）----
        // 缓存的 JWT 可能被服务端提前作废（如用户在别处重新登录，exp 未到但 1001），
        // 此时强制清掉换一张再试一次，而不是把 cookie 误判成过期
        var jwt2 = jwt
        let rows: [TraeRow]
        switch fetchSessions(jwt: jwt, fromEpoch: fromEpoch, toEpoch: toEpoch) {
        case .success(let r):
            rows = r
        case .failed(let msg):
            return (.failed(msg), auth)
        case .authExpired:
            // 强制换签（清 JWT；Session 也不行时 ensureJWT 内部会走 Login 重造）
            auth.jwt = ""
            auth.jwtExp = 0
            switch ensureJWT(passportCookie: passportCookie, auth: &auth) {
            case .success(let fresh):
                jwt2 = fresh
            case .notConfigured, .authExpired: return (.authExpired, auth)
            case .failed(let msg): return (.failed(msg), auth)
            }
            switch fetchSessions(jwt: jwt2, fromEpoch: fromEpoch, toEpoch: toEpoch) {
            case .success(let r): rows = r
            case .authExpired: return (.authExpired, auth)
            case .failed(let msg): return (.failed(msg), auth)
            }
        }

        // ---- 3. 积分汇总（官方账单口径；失败不致命，按小时节流由调用方控制）----
        var consumed: Double?
        var total: Double?
        if fetchEnt {
            let entBody = "{\"require_usage\":true}"
            let ent = post(url: TraeAPI.base + TraeAPI.entUsagePath, auth: "Cloud-IDE-JWT \(jwt2)", body: entBody)
            if let data = ent.data,
               let resp = try? JSONDecoder().decode(TraeEntUsageResponse.self, from: data),
               let s = resp.usage_summary {
                consumed = s.consumed_amount
                total = s.total_amount
            }
        }

        return (.success(rows: rows, consumed: consumed, total: total), auth)
    }

    private enum SessionsOutcome {
        case success([TraeRow])
        case authExpired
        case failed(String)
    }

    // MARK: 每日签到

    enum TraeCheckinOutcome: Equatable, Error {
        case claimed(credits: Double)   // 签到成功（本次到账积分 = 基础 + 会员加成）
        case already                    // 今天已签过
        case disabled                   // 账号未开启签到
        case notConfigured
        case authExpired
        case failed(String)
    }

    enum CheckinPlan: Equatable {
        case claim, already, disabled
    }

    /// 纯决策：enable=false 不参与；checked_in=true 已签；其余尝试领取
    static func checkinPlan(enable: Bool?, checkedIn: Bool?) -> CheckinPlan {
        if enable == false { return .disabled }
        if checkedIn == true { return .already }
        return .claim
    }

    /// 每日签到：先查状态，未签则领取。JWT 失效自动强制换签重试一次（与 run 同套路）。
    static func checkin(passportCookie: String, auth: TraeAuth) -> (outcome: TraeCheckinOutcome, auth: TraeAuth) {
        var auth = auth
        guard !passportCookie.isEmpty else { return (.notConfigured, auth) }

        var jwt = ""
        switch ensureJWT(passportCookie: passportCookie, auth: &auth) {
        case .success(let token): jwt = token
        case .notConfigured: return (.notConfigured, auth)
        case .authExpired: return (.authExpired, auth)
        case .failed(let msg): return (.failed(msg), auth)
        }

        // 1. 查签到状态（1001 → 强制换签重试一次）
        let status: TraeCheckinResponse
        switch checkinWithRetry(path: TraeAPI.checkinStatusPath, body: "{}",
                                passportCookie: passportCookie, auth: &auth, jwt: &jwt) {
        case .success(let r): status = r
        case .failure(let o): return (o, auth)
        }
        switch checkinPlan(enable: status.enable, checkedIn: status.checked_in) {
        case .already: return (.already, auth)
        case .disabled: return (.disabled, auth)
        case .claim: break
        }

        // 2. 领取（官方客户端同样带 req_source）
        switch checkinWithRetry(path: TraeAPI.checkinClaimPath, body: "{\"req_source\":1}",
                                passportCookie: passportCookie, auth: &auth, jwt: &jwt) {
        case .success(let r):
            if let code = r.code, code != 0 {
                return (.failed("签到失败 code \(code)\(r.message.map { "：\($0)" } ?? "")"), auth)
            }
            return (.claimed(credits: (r.credits ?? 0) + (r.extra_credits ?? 0)), auth)
        case .failure(let o): return (o, auth)
        }
    }

    /// 带一次强制换签重试的签到请求（status 与 claim 共用）
    private static func checkinWithRetry(path: String, body: String,
                                         passportCookie: String, auth: inout TraeAuth,
                                         jwt: inout String) -> Result<TraeCheckinResponse, TraeCheckinOutcome> {
        func call(_ token: String) -> Result<TraeCheckinResponse, TraeCheckinOutcome> {
            switch checkinCall(path: path, jwt: token, body: body) {
            case .success(let r): return .success(r)
            case .authExpired: return .failure(.authExpired)
            case .failed(let m): return .failure(.failed(m))
            }
        }
        switch call(jwt) {
        case .success(let r):
            return .success(r)
        case .failure(.authExpired):
            auth.jwt = ""
            auth.jwtExp = 0
            switch ensureJWT(passportCookie: passportCookie, auth: &auth) {
            case .success(let fresh):
                jwt = fresh
                return call(fresh)
            case .notConfigured, .authExpired: return .failure(.authExpired)
            case .failed(let m): return .failure(.failed(m))
            }
        case .failure(let other):
            return .failure(other)
        }
    }

    private enum CheckinHTTPOutcome {
        case success(TraeCheckinResponse)
        case authExpired
        case failed(String)
    }

    private static func checkinCall(path: String, jwt: String, body: String) -> CheckinHTTPOutcome {
        let r = post(url: TraeAPI.base + path, auth: "Cloud-IDE-JWT \(jwt)", body: body)
        guard let data = r.data else { return .failed(r.error ?? "无响应") }
        guard let resp = try? JSONDecoder().decode(TraeCheckinResponse.self, from: data) else {
            return .failed("签到响应解析失败")
        }
        if let code = resp.code, code == 1001 { return .authExpired }
        return .success(resp)
    }

    /// 分页拉取会话明细。错误码：1001 = JWT/会话失效；9004 = 参数不合法；成功响应没有 code 字段。
    private static func fetchSessions(jwt: String, fromEpoch: Int64, toEpoch: Int64) -> SessionsOutcome {
        var rows: [TraeRow] = []
        var page = 1
        while page <= TraeAPI.maxPages {
            let body = "{\"start_time\":\(fromEpoch),\"end_time\":\(toEpoch)," +
                       "\"page_size\":\(TraeAPI.pageSize),\"page_num\":\(page),\"usage_type\":[7]}"
            let r = post(url: TraeAPI.base + TraeAPI.usagePath, auth: "Cloud-IDE-JWT \(jwt)", body: body)
            guard let data = r.data else { return .failed(r.error ?? "无响应") }
            guard let resp = try? JSONDecoder().decode(TraeUsageResponse.self, from: data) else {
                return .failed("响应解析失败")
            }
            if let code = resp.code {
                if code == 1001 { return .authExpired }
                return .failed("API code \(code)")
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
        return .success(rows)
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
        // Trae 的 input_token 是 OpenAI/智谱口径：总量，已包含 cache_read。
        // 库内统一 Anthropic 口径（input=净输入，三项相加=总 prompt），否则合计会重复计算缓存。
        let gross = extra?.input_token ?? 0
        let cached = extra?.cache_read_token ?? 0
        return TraeRow(
            sessionID: sid,
            model: s.model_name ?? "unknown",
            input: max(0, gross - cached),
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
