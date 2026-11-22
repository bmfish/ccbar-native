import Foundation

// MARK: - 多 Mac 用量云同步
//
// 服务端 cc-service 提供两个接口（Bearer Token 鉴权）：
//   POST /api/usage/events            批量 upsert（≤5000/批，主键 source + request_id）
//   GET  /api/usage/events?after=seq  按 seq 游标增量拉取
//
// 上传：只读本机 usage_log 中 origin='local' 的行，按源水位回看 3 天（每日再回看 30 天对账），
// 整批 2xx 后推进水位；服务端内容未变化时不动 seq，避免重复下载。
// 下载：写回 usage_log 并标记 origin='cloud'；同主键的本机行优先，绝不覆盖。
// 双向都不会把拉回来的数据再传回去（origin 过滤），避免回声。

/// 一条与 cc-service 对齐的用量明细（createdAt 为 epoch 秒）
struct UsageCloudEvent: Codable, Equatable {
    var source: String
    var requestId: String
    var appType: String?
    var model: String?
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheCreationTokens: Int64
    var reasoningTokens: Int64
    var totalCostUsd: Double
    var credits: Double
    var createdAt: Int64
    var requestCount: Int64
    var account: String
}

enum UsageSync {

    struct Config {
        var baseURL: String
        var username: String = ""
        var password: String = ""
        /// 已登录的会话 Token（本地保存，不展示）
        var token: String = ""
    }

    struct Outcome {
        var uploaded = 0
        var pulled = 0
        var error: String?
        var skipped = false
        /// 本次登录新拿到的会话 Token，调用方负责持久化
        var token: String?

        var isSuccess: Bool { error == nil && !skipped }
    }

    /// 单批大小（服务端上限 5000，客户端取小值控制内存与请求时长）
    static let batchSize = 500
    /// 增量回看：覆盖跨零点迟到与会话续聊
    static let incrementalOverlap: Int64 = 3 * 86_400
    /// 每日全量对账：回看 30 天，兜住老数据被改写
    static let reconcileInterval: TimeInterval = 86_400
    static let reconcileLookback: Int64 = 30 * 86_400

    private static let gate = NSLock()
    private static var running = false

    /// 地址归一化：去尾部斜杠；未带 /api 前缀时自动补上
    static func normalizedBaseURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.lowercased().hasSuffix("/api") {
            text += "/api"
        }
        guard URL(string: text) != nil else { return nil }
        return text
    }

    static func run(store: StatsStore, config: Config,
                    now: Date = Date()) -> Outcome {
        guard let base = normalizedBaseURL(config.baseURL) else {
            store.setUsageSyncStatus("未配置服务地址")
            return Outcome(skipped: true)
        }
        var token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        var outcome = Outcome()
        if token.isEmpty {
            let username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, !config.password.isEmpty else {
                store.setUsageSyncStatus("未登录，请在设置里输入用户名和密码")
                return Outcome(skipped: true)
            }
            let login = login(base: base, username: username, password: config.password)
            guard let newToken = login.token else {
                store.setUsageSyncStatus("登录失败：\(login.error ?? "未知错误")")
                return Outcome(error: login.error ?? "登录失败")
            }
            token = newToken
            outcome.token = newToken
        }

        // 换账号后清空上一个账号的云端数据与游标，本机数据会重新上传到新账号
        if !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let identity = store.usageSyncMeta("identity")
            let username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if identity != username {
                store.resetUsageCloudState()
                store.setUsageSyncMeta("identity", value: username)
            }
        }

        gate.lock()
        if running {
            gate.unlock()
            return outcome
        }
        running = true
        gate.unlock()
        defer {
            gate.lock()
            running = false
            gate.unlock()
        }

        store.setUsageSyncStatus("同步中…")
        let deviceId = store.usageDeviceID()

        if let error = upload(store: store, base: base, token: token,
                              deviceId: deviceId, now: now, uploaded: &outcome.uploaded) {
            store.setUsageSyncStatus("上传失败：\(error)")
            outcome.error = error
            return outcome
        }

        if let error = uploadQuota(store: store, base: base, token: token, deviceId: deviceId) {
            store.setUsageSyncStatus("积分账单上传失败：\(error)")
            outcome.error = error
            return outcome
        }

        let (pullError, pulled) = download(store: store, base: base, token: token)
        outcome.pulled = pulled
        if let pullError {
            store.setUsageSyncStatus("拉取失败：\(pullError)")
            outcome.error = pullError
            return outcome
        }

        store.setUsageSyncStatus("已同步：上传 \(outcome.uploaded) 条 · 拉取 \(outcome.pulled) 条")
        ccLog("用量云同步完成：上传 \(outcome.uploaded) 条, 拉取 \(outcome.pulled) 条")
        return outcome
    }

    // MARK: 登录

    private struct LoginRequest: Encodable {
        let username: String
        let password: String
    }

    private struct LoginResponse: Decodable {
        let token: String
        let userId: Int64
        let username: String
    }

    /// 用户名密码换会话 Token；失败返回可直接展示的中文原因。
    static func login(base: String, username: String, password: String) -> (token: String?, error: String?) {
        guard let url = URL(string: base + "/auth/login"),
              let body = try? JSONEncoder().encode(LoginRequest(username: username, password: password)) else {
            return (nil, "请求构造失败")
        }
        let (data, status, error) = request(url: url, method: "POST", token: "", body: body)
        if let error { return (nil, error) }
        guard let status else { return (nil, "无响应") }
        if status == 401 { return (nil, "用户名或密码错误") }
        guard (200..<300).contains(status) else {
            return (nil, httpError(status, data: data))
        }
        guard let data, let response = try? JSONDecoder().decode(LoginResponse.self, from: data) else {
            return (nil, "响应解析失败")
        }
        return (response.token, nil)
    }

    // MARK: 上传

    /// 逐源上传本机明细；返回首个错误（成功为 nil）
    private static func upload(store: StatsStore, base: String, token: String,
                               deviceId: String, now: Date, uploaded: inout Int) -> String? {
        let sources = store.usageLocalSources()
        guard !sources.isEmpty else { return nil }
        let reconcileAt = TimeInterval(store.usageSyncMeta("reconcile_at")) ?? 0
        let needsReconcile = now.timeIntervalSince1970 - reconcileAt >= reconcileInterval

        for source in sources {
            let watermark = Int64(store.usageSyncMeta("watermark_\(source)")) ?? 0
            var start: Int64 = 0
            if watermark > 0 {
                let lookback = needsReconcile ? reconcileLookback : incrementalOverlap
                start = max(watermark - lookback, 0)
            }
            var cursor = watermark > 0 ? StatsStore.UsageKeyset(createdAt: start, requestID: "") : nil
            var maxSeen = watermark

            while true {
                let batch = store.usageLocalBatch(source: source, after: cursor, limit: batchSize)
                if batch.isEmpty { break }
                if let error = post(base: base, token: token, deviceId: deviceId, events: batch) {
                    return "\(source)：\(error)"
                }
                uploaded += batch.count
                if let last = batch.last {
                    cursor = StatsStore.UsageKeyset(createdAt: last.createdAt, requestID: last.requestId)
                }
                maxSeen = max(maxSeen, batch.map(\.createdAt).max() ?? 0)
                store.setUsageSyncMeta("watermark_\(source)", value: String(maxSeen))
                if batch.count < batchSize { break }
            }
        }

        if needsReconcile {
            store.setUsageSyncMeta("reconcile_at", value: String(Int(now.timeIntervalSince1970)))
        }
        return nil
    }

    private struct UploadRequest: Encodable {
        let deviceId: String
        let events: [UsageCloudEvent]
    }

    private struct UploadResult: Decodable {
        let received: Int
        let saved: Int
    }

    private static func post(base: String, token: String, deviceId: String,
                             events: [UsageCloudEvent]) -> String? {
        guard let url = URL(string: base + "/usage/events"),
              let body = try? JSONEncoder().encode(UploadRequest(deviceId: deviceId, events: events)) else {
            return "请求构造失败"
        }
        let (data, status, error) = request(url: url, method: "POST", token: token, body: body)
        if let error { return error }
        guard let status else { return "无响应" }
        guard (200..<300).contains(status) else {
            return httpError(status, data: data)
        }
        guard let data, let result = try? JSONDecoder().decode(UploadResult.self, from: data) else {
            return "响应解析失败"
        }
        if result.received != events.count {
            return "服务端收到 \(result.received)/\(events.count) 条"
        }
        return nil
    }

    // MARK: 积分账单

    private struct QuotaSnapshot: Encodable {
        let account: String
        let slot: Int
        let consumed: Double
        let total: Double
        let updatedAt: Int64
    }

    private struct QuotaUploadRequest: Encodable {
        let deviceId: String
        let quotas: [QuotaSnapshot]
    }

    private struct QuotaUploadResult: Decodable {
        let received: Int
        let saved: Int
    }

    /// 把本机 Trae 官方账单（已用 / 总额）上报到云端，供管理后台展示剩余积分。
    private static func uploadQuota(store: StatsStore, base: String, token: String,
                                    deviceId: String) -> String? {
        let snapshots = store.traeQuotaSnapshots()
        guard !snapshots.isEmpty else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        let quotas = snapshots.map { snapshot in
            QuotaSnapshot(
                account: snapshot.uid,
                slot: snapshot.slot,
                consumed: snapshot.consumed,
                total: snapshot.total,
                updatedAt: snapshot.updatedAt > 0 ? snapshot.updatedAt : now
            )
        }
        guard let url = URL(string: base + "/usage/quota"),
              let body = try? JSONEncoder().encode(
                QuotaUploadRequest(deviceId: deviceId, quotas: quotas)) else {
            return "请求构造失败"
        }
        let (data, status, error) = request(url: url, method: "POST", token: token, body: body)
        if let error { return error }
        guard let status else { return "无响应" }
        guard (200..<300).contains(status) else {
            return httpError(status, data: data)
        }
        guard let data, let result = try? JSONDecoder().decode(QuotaUploadResult.self, from: data) else {
            return "响应解析失败"
        }
        if result.received != quotas.count {
            return "服务端收到 \(result.received)/\(quotas.count) 个账号"
        }
        return nil
    }

    // MARK: 下载

    private struct PullResponse: Decodable {
        let events: [UsageCloudEvent]
        let nextSeq: Int64
    }

    private static func download(store: StatsStore, base: String, token: String) -> (String?, Int) {
        var cursor = Int64(store.usageSyncMeta("seq")) ?? 0
        var pulled = 0
        var pages = 0

        while pages < 400 {
            guard let url = URL(string: base + "/usage/events?after=\(cursor)&limit=\(batchSize)") else {
                return ("请求构造失败", pulled)
            }
            let (data, status, error) = request(url: url, method: "GET", token: token, body: nil)
            if let error { return (error, pulled) }
            guard let status else { return ("无响应", pulled) }
            guard (200..<300).contains(status) else {
                return (httpError(status, data: data), pulled)
            }
            guard let data, let response = try? JSONDecoder().decode(PullResponse.self, from: data) else {
                return ("响应解析失败", pulled)
            }

            if !response.events.isEmpty {
                pulled += store.applyUsageCloudEvents(response.events)
            }
            let previous = cursor
            let next = max(cursor, response.nextSeq)
            if next != cursor {
                store.setUsageSyncMeta("seq", value: String(next))
                cursor = next
            }
            pages += 1
            if response.events.count < batchSize { break }
            if cursor <= previous { break }
        }
        return (nil, pulled)
    }

    // MARK: HTTP

    private static func request(url: URL, method: String, token: String,
                                body: Data?) -> (Data?, Int?, String?) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        let semaphore = DispatchSemaphore(value: 0)
        var out: (Data?, Int?, String?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                out.2 = error.localizedDescription
            } else if let http = response as? HTTPURLResponse {
                out.1 = http.statusCode
                out.0 = data
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return out
    }

    private static func httpError(_ status: Int, data: Data?) -> String {
        if status == 401 { return "登录已过期，请重新登录" }
        let body = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(body.prefix(120))"
    }
}
