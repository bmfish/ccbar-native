import Cocoa
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置窗口（SwiftUI）
//
// 原 AppKit 手写约束版两次出现布局事故（按钮被挤出、数据源行压塌），
// 整体改为 SwiftUI：滚动内容 + 钉底按钮栏由布局系统保证，不再手搓约束。

/// 数据源行草稿（编辑态，保存时才写回 Settings）
struct SourceRowDraft: Identifiable {
    enum StatusKind { case ok, muted, warn }

    let id: String
    let name: String
    let defaultPath: String
    var enabled: Bool
    var path: String
    /// HTTP 型源（Trae）的登录凭据；SQLite 源不使用
    var credential: String = ""
    var isHTTP: Bool = false
    var statusText: String = ""
    var statusKind: StatusKind = .muted
}

/// 设置草稿模型：窗口内编辑，点“保存”统一校验后写入并生效
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var theme: Theme = .classic
    @Published var refreshIntervalText = ""
    @Published var warningThresholdText = ""
    @Published var notifyIntervalText = ""
    @Published var ledThresholdText = ""
    @Published var budgetText = ""
    @Published var priceText = ""
    @Published var warningEnabled = true
    @Published var launchAtLogin = false
    @Published var menuPetEnabled = true
    @Published var menuEmojiEnabled = true
    @Published var popoverWide = false
    @Published var sources: [SourceRowDraft] = []
    @Published var language: AppLanguage = .system
    @Published var lastBackupDate = ""
    /// Trae "立即同步"进行中（按钮禁用防连点）
    @Published var traeSyncing = false
    /// Trae 官方积分账单（已用 / 总额），数据源卡片底部展示
    @Published var traeCredits: (consumed: Double, total: Double)?

    let settings: Settings
    let onSaved: () -> Void
    /// 主题落点（测试里替换，避免污染真实偏好）
    var applyTheme: (Theme) -> Void = { Theme.current = $0 }
    /// 开机启动落点（测试里替换，避免动系统登录项）
    var applyLaunchAtLogin: (Bool) -> Void = { _ in }
    /// 弹窗提示（测试里可替换，避免 NSAlert 卡住跑测）
    var showAlert: (String, String) -> Void = { title, body in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    init(settings: Settings, onSaved: @escaping () -> Void) {
        self.settings = settings
        self.onSaved = onSaved
        self.applyLaunchAtLogin = { settings.setLaunchAtLogin($0) }
        reload()
    }

    /// 从 Settings 重读全部字段（打开窗口、重置后调用）
    func reload() {
        theme = Theme.current
        refreshIntervalText = "\(settings.refreshInterval)"
        warningThresholdText = "\(settings.warningThreshold)"
        notifyIntervalText = "\(settings.notifyInterval)"
        ledThresholdText = "\(settings.ledRedThreshold)"
        budgetText = settings.monthlyBudgetUsd > 0 ? String(format: "%g", settings.monthlyBudgetUsd) : ""
        priceText = settings.defaultTokenPrice > 0 ? String(format: "%g", settings.defaultTokenPrice) : ""
        warningEnabled = settings.warningEnabled
        launchAtLogin = settings.launchAtLogin
        menuPetEnabled = settings.menuPetEnabled
        menuEmojiEnabled = settings.menuEmojiEnabled
        popoverWide = settings.popoverWide
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
        lastBackupDate = UserDefaults.standard.string(forKey: "lastAutoBackupDate") ?? ""

        let configs = settings.sourceConfigs
        sources = SourceRegistry.adapters.map { adapter in
            let config = configs.first { $0.id == adapter.id }
            return SourceRowDraft(
                id: adapter.id,
                name: adapter.name,
                defaultPath: adapter.defaultPath,
                enabled: config?.enabled ?? false,
                path: config?.dbPath ?? adapter.defaultPath
            )
        }
        // Trae 是 HTTP 源（不在 SourceRegistry 里），凭据代替路径
        if let trae = configs.first(where: { $0.id == "trae" }) {
            sources.append(SourceRowDraft(
                id: "trae", name: "Trae", defaultPath: "",
                enabled: trae.enabled, path: "",
                credential: trae.credential ?? "", isHTTP: true))
        }
        refreshSourceStatus()
    }

    // MARK: 数据源状态与路径校验

    /// 数据源连接状态（来自 StatsStore 的诊断信息）
    func refreshSourceStatus() {
        let statuses = AppDelegate.shared?.store.sourceStatus ?? [:]
        var credits: (consumed: Double, total: Double)?
        for i in sources.indices {
            let raw = statuses[sources[i].id] ?? ""
            var s = L(raw)
            // Trae 附加官方积分账单（已连接时）
            if sources[i].isHTTP, raw.contains("已连接"),
               let ent = AppDelegate.shared?.store.traeEntSummary() {
                credits = (ent.consumed, ent.total)
                s += String(format: L(" · 积分 %@/%@"), Self.fmtCredits(ent.consumed), Self.fmtCredits(ent.total))
            }
            sources[i].statusText = s
            if raw.contains("已连接") {
                sources[i].statusKind = .ok
            } else if raw == "未启用" || raw == "未配置登录" || raw.isEmpty {
                sources[i].statusKind = .muted
            } else {
                sources[i].statusKind = .warn
            }
        }
        traeCredits = credits
    }

    /// 积分显示：整数不带小数点，小数保留两位
    static func fmtCredits(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 100_000 ? String(Int(v)) : String(format: "%.2f", v)
    }

    /// Trae "立即同步"：把草稿凭据落库（只动 trae 一条）→ rebuild → 强制同步一次。
    /// 跳过节流与夜间静默——用户明确操作，粘贴新 cookie 后点一下立刻验证，不用等窗口。
    func syncTraeNow() {
        guard let i = sources.firstIndex(where: { $0.id == "trae" }) else { return }
        let credential = sources[i].credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !traeSyncing else { return }

        var configs = settings.sourceConfigs
        if let ci = configs.firstIndex(where: { $0.id == "trae" }) {
            configs[ci].enabled = sources[i].enabled
            configs[ci].credential = credential
        } else {
            configs.append(SourceConfig(id: "trae", enabled: sources[i].enabled,
                                        dbPath: "", credential: credential))
        }
        settings.sourceConfigs = configs
        traeSyncing = true
        sources[i].statusText = L("同步中…")
        sources[i].statusKind = .muted
        let snapshot = configs   // 主线程快照，避免后台队列读设置
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let store = AppDelegate.shared?.store else { return }
            store.rebuild(configs: snapshot)
            store.syncTraeIfNeeded(force: true)
            DispatchQueue.main.async {
                self.traeSyncing = false
                self.refreshSourceStatus()
            }
        }
    }

    /// Trae 源无库路径可校验；SQLite 源只读试开一次检查必需表，结果就地显示（保存时才生效）
    func validateSource(id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        if sources[i].isHTTP {
            // 粘贴了凭据就试拉一次会话（不打扰用户，失败静默）
            sources[i].statusText = sources[i].credential.isEmpty
                ? L("粘贴后将在保存后生效")
                : L("已填写（保存后生效）")
            sources[i].statusKind = sources[i].credential.isEmpty ? .muted : .ok
            return
        }
        let path = sources[i].path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let adapter = SourceRegistry.adapter(for: id) else { return }

        if !FileManager.default.fileExists(atPath: path) {
            sources[i].statusText = L("文件不存在")
            sources[i].statusKind = .warn
        } else if let error = Self.validateDB(path: path, requiredTables: adapter.requiredTables) {
            sources[i].statusText = error
            sources[i].statusKind = .warn
        } else {
            sources[i].statusText = L("表结构正确（保存后生效）")
            sources[i].statusKind = .ok
        }
    }

    static func validateDB(path: String, requiredTables: [String]) -> String? {
        var db: OpaquePointer?
        let escaped = path.replacingOccurrences(of: "'", with: "%27")
        guard sqlite3_open_v2("file:\(escaped)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return L("打不开（被占用或损坏）")
        }
        defer { sqlite3_close_v2(db) }
        let list = requiredTables.joined(separator: "','")
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('\(list)')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return L("校验失败") }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) >= Int64(requiredTables.count) {
            return nil
        }
        return L("缺少必需表")
    }

    /// 选择数据源库文件
    func browseSource(id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }),
              let adapter = SourceRegistry.adapter(for: id) else { return }
        let panel = NSOpenPanel()
        panel.title = String(format: L("选择 %@ 数据库文件"), adapter.name)
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data,
                                     UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self.sources[i].path = url.path
                self.validateSource(id: id)
            }
        }
    }

    // MARK: 保存 / 重置

    func save() {
        // 数字字段整体校验，任一无效就阻止保存并指出（原来非法值会被静默忽略）
        var invalid: [String] = []
        let interval = Int(refreshIntervalText)
        if interval == nil || !(5...3000).contains(interval!) { invalid.append(L("刷新间隔（5 ~ 3000 秒）")) }
        let threshold = Int(warningThresholdText)
        if threshold == nil || threshold! <= 0 { invalid.append(L("预警阈值（正整数，万）")) }
        let notify = Int(notifyIntervalText)
        if notify == nil || notify! < 0 { invalid.append(L("通知间隔（≥ 0 的整数，万，0=关闭）")) }
        let led = Int(ledThresholdText)
        if led == nil || led! < 0 { invalid.append(L("红色门槛（≥ 0 的整数，万，0=不变红）")) }
        let budget = Double(budgetText.isEmpty ? "0" : budgetText)
        if budget == nil || budget! < 0 { invalid.append(L("月度预算（≥ 0 的数字，$，0=关闭）")) }
        let price = Double(priceText.isEmpty ? "0" : priceText)
        if price == nil || price! < 0 { invalid.append(L("默认单价（≥ 0 的数字，$/M tokens，0=关闭）")) }
        if !invalid.isEmpty {
            showAlert(L("无法保存"), L("以下字段无效：") + "\n" + invalid.joined(separator: "\n"))
            return
        }

        settings.refreshInterval = interval!
        // 数据源：勾选状态 + 路径（留空回落默认路径）+ HTTP 源凭据
        settings.sourceConfigs = sources.map { row in
            let path = row.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return SourceConfig(id: row.id, enabled: row.enabled,
                                dbPath: path.isEmpty ? row.defaultPath : path,
                                credential: row.isHTTP
                                    ? row.credential.trimmingCharacters(in: .whitespacesAndNewlines)
                                    : nil)
        }
        settings.warningThreshold = threshold!
        settings.warningEnabled = warningEnabled
        applyLaunchAtLogin(launchAtLogin)
        settings.menuPetEnabled = menuPetEnabled
        settings.menuEmojiEnabled = menuEmojiEnabled
        settings.popoverWide = popoverWide
        settings.notifyInterval = notify!
        settings.ledRedThreshold = led!
        settings.monthlyBudgetUsd = budget!
        settings.defaultTokenPrice = price!
        applyTheme(theme)
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")

        showAlert(L("设置已保存"), L("新的设置将在下次刷新时生效"))
        onSaved()
    }

    func reset() {
        settings.refreshInterval = 30
        settings.resetSourceConfigs()
        settings.warningThreshold = 50
        settings.warningEnabled = true
        applyLaunchAtLogin(false)
        settings.menuPetEnabled = true
        settings.menuEmojiEnabled = true
        settings.popoverWide = false
        settings.ledRedThreshold = 100
        settings.monthlyBudgetUsd = 0
        settings.defaultTokenPrice = 0
        reload()
    }

    // MARK: 按钮栏动作

    func checkForUpdates() {
        UpdateChecker.check()
    }

    /// 备份统计库（用量历史是长期资产，一键导出独立 db 文件）
    func backupData() {
        let panel = NSSavePanel()
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "")
        panel.nameFieldStringValue = "ccbar-backup-\(stamp).db"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ok = AppDelegate.shared?.store.backup(to: url.path) ?? false
        if ok {
            showAlert(L("备份完成"),
                      L("统计库已备份到：") + "\n\(url.path)" + L("\n恢复方式：退出 ccBar 后用备份文件替换\n~/Library/Application Support/ccbar/ccbar.db"))
        } else {
            showAlert(L("备份失败"), L("统计库未打开或目标位置不可写"))
        }
    }

    // MARK: 主题包导入/导出

    /// 导出当前选中的主题为 JSON 主题包（可直接分享给其他用户导入）
    func exportTheme() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ccbar-theme-\(theme.name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try JSONEncoder().encode(theme).write(to: url)
            showAlert(L("导出完成"), L("主题包已保存到：") + "\n\(url.path)")
        } catch {
            showAlert(L("导出失败"), error.localizedDescription)
        }
    }

    /// 当前草稿主题是否为自定义（可删除）
    var themeIsCustom: Bool { theme.id.hasPrefix("custom-") }

    /// 删除选中的自定义主题（内置主题不可删）
    func deleteTheme() {
        guard themeIsCustom else { return }
        let name = theme.name
        Theme.customThemes.removeAll { $0.id == theme.id }
        theme = .classic
        showAlert(L("删除成功"), String(format: L("主题「%@」已删除"), name))
    }

    /// 导出明细 CSV（换机迁移 / Excel 查看）
    func exportData() {
        let panel = NSSavePanel()
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "")
        panel.nameFieldStringValue = "ccbar-export-\(stamp).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if AppDelegate.shared?.store.exportCSV(to: url.path) == true {
            showAlert(L("导出完成"), L("明细已导出到：") + "\n\(url.path)")
        } else {
            showAlert(L("导出失败"), L("统计库未打开或目标位置不可写"))
        }
    }

    /// 导入明细 CSV（幂等：主键去重，同一文件重复导零新增）
    func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let r = AppDelegate.shared?.store.importCSV(from: url.path) ?? (read: 0, inserted: 0, skipped: 0)
        if r.skipped == -1 {
            showAlert(L("导入失败"), L("不是 ccBar 导出的明细 CSV（表头不符）"))
            return
        }
        showAlert(L("导入完成"),
                  String(format: L("共读取 %d 行 · 新增 %d 行 · 跳过 %d 行（重复或非法）"),
                         r.read, r.inserted, r.skipped))
    }

    /// 多机合并：导入另一台机器导出的 ccbar.db（主键去重，重复行跳过）
    func mergeDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data,
                                     UTType(filenameExtension: "sqlite") ?? .data]
        panel.canChooseDirectories = false
        panel.message = L("选择另一台机器的 ccbar.db（统计库），明细将按主键去重合并")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let r = AppDelegate.shared?.store.mergeFromDB(path: url.path) ?? (read: 0, inserted: 0)
        if r.read == 0 && r.inserted == 0 {
            showAlert(L("合并失败"), L("不是有效的 ccBar 统计库（缺 usage_log 表或文件打不开）"))
            return
        }
        showAlert(L("合并完成"),
                  String(format: L("共读取 %d 行 · 新增 %d 行（重复自动跳过）"), r.read, r.inserted))
        AppDelegate.shared?.refreshData()
    }

    /// 打开自动备份目录（不存在则先建）
    func openBackupFolder() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ccbar/backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 导入 JSON 主题包：加入可选列表并选中（点保存后生效）
    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        guard var imported = Theme.fromJSON(data) else {
            showAlert(L("导入失败"), L("不是有效的 ccBar 主题包"))
            return
        }
        let existed = Theme.customThemes.contains { $0.name == imported.name }
        imported = Theme.upsertCustom(imported)
        theme = imported
        showAlert(L("导入成功"),
                  String(format: L(existed ? "主题「%@」已覆盖更新" : "主题「%@」已加入可选列表"),
                         imported.name))
    }

    /// 重命名当前选中的自定义主题（弹窗带输入框）
    func renameTheme() {
        guard themeIsCustom else { return }
        let alert = NSAlert()
        alert.messageText = L("重命名主题")
        alert.informativeText = theme.name
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = theme.name
        alert.accessoryView = field
        alert.addButton(withTitle: L("确定"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        Theme.renameCustom(id: theme.id, to: newName)
        theme = Theme.find(id: theme.id) ?? theme
    }
}

// MARK: - 根视图

struct SettingsRootView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var dirty = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(nsColor: Design.backgroundDark).opacity(0.8))
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        appearanceCard
                        sourcesCard
                        refreshCard
                        behaviorCard
                        dataCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                }
                Rectangle().fill(Color(nsColor: Design.separatorColor)).frame(height: 1)
                buttonBar
            }
            if vm.theme.scanlines {
                ScanlineShape().allowsHitTesting(false)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onReceive(vm.objectWillChange) { _ in
            if !dirty { DispatchQueue.main.async { dirty = true } }
        }
    }

    // MARK: 页头

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("设置"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                Text(L("改动需点击保存后生效"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
            }
            Spacer()
        }
    }

    // MARK: 外观

    private var appearanceCard: some View {
        section(L("外观")) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    rowLabel(L("主题风格"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Theme.allThemes) { themeChip($0) }
                        }
                    }
                    .frame(height: 26)
                    Menu {
                        Button(L("导入")) { vm.importTheme() }
                        Button(L("导出")) { vm.exportTheme() }
                        if vm.themeIsCustom {
                            Button(L("重命名")) { vm.renameTheme() }
                            Button(L("删除")) { vm.deleteTheme() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                            .foregroundColor(Color(nsColor: Design.textSecondary))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .frame(height: 32)
                rowDivider
                HStack(spacing: 8) {
                    rowLabel(L("界面语言"))
                    Picker("", selection: $vm.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Text(L("重启后生效"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                    Spacer(minLength: 0)
                }
                .frame(height: 32)
                rowDivider
                HStack(spacing: 8) {
                    rowLabel(L("宽版弹窗"))
                    Toggle("", isOn: $vm.popoverWide)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Color(nsColor: Design.successColor))
                    Text(L("380pt · 菜单栏弹窗展开宽度"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                    Spacer(minLength: 0)
                }
                .frame(height: 32)
            }
        }
    }

    // MARK: 数据源

    private var sourcesCard: some View {
        let connected = vm.sources.filter { $0.statusKind == .ok }.count
        return section(L("数据源"), trailing: String(format: L("%d 个已连接"), connected)) {
            VStack(spacing: 0) {
                ForEach($vm.sources) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(row.statusKind))
                                .frame(width: 6, height: 6)
                            Toggle("", isOn: $row.enabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .controlSize(.mini)
                            Text(row.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(nsColor: Design.textPrimary))
                                .frame(width: 74, alignment: .leading)
                            if row.isHTTP {
                                pathField($row.credential,
                                          placeholder: L("粘贴 trae.cn 登录后的 sessionid cookie 值")) {
                                    vm.validateSource(id: row.id)
                                }
                                .help(L("在浏览器登录 trae.cn 后，从 DevTools 的 Cookie 里复制 sessionid 的值"))
                                pillButton(vm.traeSyncing ? L("同步中…") : L("立即同步"),
                                            disabled: vm.traeSyncing || row.credential.isEmpty) {
                                    vm.syncTraeNow()
                                }
                            } else {
                                pathField($row.path, placeholder: row.defaultPath) {
                                    vm.validateSource(id: row.id)
                                }
                                .help(row.path.isEmpty ? row.defaultPath : row.path)
                                pillButton(L("浏览")) { vm.browseSource(id: row.id) }
                            }
                        }
                        if !row.statusText.isEmpty {
                            Text(row.statusText)
                                .font(.system(size: 9))
                                .foregroundColor(statusColor(row.statusKind))
                                .lineLimit(1)
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.vertical, 6)
                    if row.id != vm.sources.last?.id {
                        rowDivider
                    }
                }
                if let cr = vm.traeCredits {
                    creditsFooter(cr)
                }
            }
        }
    }

    private func creditsFooter(_ cr: (consumed: Double, total: Double)) -> some View {
        let pct = cr.total > 0 ? min(cr.consumed / cr.total, 1) : 0
        return VStack(spacing: 6) {
            rowDivider
            HStack(spacing: 8) {
                Text(L("积分"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.textMuted))
                    .frame(width: 24, alignment: .leading)
                Text("\(SettingsViewModel.fmtCredits(cr.consumed)) / \(SettingsViewModel.fmtCredits(cr.total))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                    .fixedSize()
                progressBar(pct)
                Text(String(format: "%.0f%%", pct * 100))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: Design.successColor))
                    .fixedSize()
            }
        }
        .padding(.top, 6)
    }

    // MARK: 刷新与预警

    private var refreshCard: some View {
        section(L("刷新与预警")) {
            VStack(spacing: 0) {
                kvRow(L("刷新间隔"), $vm.refreshIntervalText, L("秒"), "5 ~ 3000")
                rowDivider
                kvRow(L("预警阈值"), $vm.warningThresholdText, L("万"), L("超出时通知"))
                rowDivider
                kvRow(L("通知间隔"), $vm.notifyIntervalText, L("万"), L("每累计N万通知，0=关闭"))
                rowDivider
                kvRow(L("红色门槛"), $vm.ledThresholdText, L("万"), L("单次刷新增量达到变红，0=不变红"))
                rowDivider
                kvRow(L("月度预算"), $vm.budgetText, "$", L("月费用预算，0=关闭；费用页显示进度与预算线"))
                rowDivider
                kvRow(L("默认单价"), $vm.priceText, "$/M", L("未计费渠道（ZCode 等）按此单价折算，0=关闭"))
            }
        }
    }

    // MARK: 行为

    private var behaviorCard: some View {
        section(L("行为")) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 12) {
                toggleCell(L("启用用量预警"), $vm.warningEnabled)
                toggleCell(L("开机自动启动"), $vm.launchAtLogin)
                toggleCell(L("菜单栏动画伴侣（小猫随用量跑动）"), $vm.menuPetEnabled)
                toggleCell(L("菜单栏表情分级（🙂→🥵）"), $vm.menuEmojiEnabled)
            }
        }
    }

    // MARK: 数据与备份

    private var dataCard: some View {
        section(L("数据与备份")) {
            VStack(spacing: 0) {
                infoRow(L("自动备份"),
                        detail: String(format: L("上次备份 %@"), vm.lastBackupDate.isEmpty ? "-" : vm.lastBackupDate)
                            + " · " + L("每日自动")) {
                    pillButton(L("打开目录")) { vm.openBackupFolder() }
                }
                rowDivider
                infoRow(L("明细迁移"), detail: L("以 CSV 导入 / 导出逐条记录")) {
                    pillButton(L("导入 CSV")) { vm.importData() }
                    pillButton(L("导出 CSV")) { vm.exportData() }
                }
                rowDivider
                infoRow(L("多机合并"), detail: L("导入另一台机器的统计库并去重")) {
                    pillButton(L("选择数据库")) { vm.mergeDatabase() }
                }
            }
        }
    }

    // MARK: 小组件

    private func section<Content: View>(_ title: String, trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.textSecondary))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Design.successColor))
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: Design.cardFillDark)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: Design.cardBorderDark)))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color(nsColor: Design.separatorColor).opacity(0.5))
            .frame(height: 1)
    }

    private func rowLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(Color(nsColor: Design.textSecondary))
            .frame(width: 84, alignment: .leading)
    }

    private func themeChip(_ t: Theme) -> some View {
        let selected = vm.theme.id == t.id
        return Button { vm.theme = t } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: t.accent))
                    .frame(width: 8, height: 8)
                Text(t.displayName)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(Color(nsColor: selected ? Design.textPrimary : Design.textSecondary))
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(selected ? 0.14 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color(nsColor: t.accent).opacity(0.85) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func kvRow(_ label: String, _ text: Binding<String>, _ unit: String,
                       _ hint: String) -> some View {
        HStack(spacing: 8) {
            rowLabel(label)
            compactField(text)
            Text(unit)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
                .frame(width: 26, alignment: .leading)
            Text(hint)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private func compactField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(nsColor: Design.textPrimary))
            .padding(.horizontal, 6)
            .frame(width: 96, height: 24)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: Design.cardBorderDark)))
    }

    private func pathField(_ text: Binding<String>, placeholder: String,
                           onEnd: @escaping () -> Void) -> some View {
        TextField("", text: text,
                  onEditingChanged: { editing in
                      if !editing { onEnd() }
                  }, onCommit: {})
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(nsColor: Design.textSecondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: Design.cardBorderDark)))
            .overlay(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(nsColor: Design.textMuted))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .allowsHitTesting(false)
                }
            }
    }

    private func pillButton(_ title: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: disabled ? Design.textMuted : Design.textSecondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: Design.cardBorderDark)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fixedSize()
    }

    private func toggleCell(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(nsColor: Design.successColor))
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textPrimary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func progressBar(_ pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Color(nsColor: Design.successColor))
                    .frame(width: max(0, min(geo.size.width * pct, geo.size.width)))
            }
        }
        .frame(height: 4)
    }

    private func infoRow<Actions: View>(_ label: String, detail: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textSecondary))
                .frame(width: 74, alignment: .leading)
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: Design.textMuted))
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 6) { actions() }
        }
        .frame(height: 34)
    }

    private func statusColor(_ kind: SourceRowDraft.StatusKind) -> Color {
        switch kind {
        case .ok: return Color(nsColor: Design.successColor)
        case .muted: return Color(nsColor: Design.textMuted)
        case .warn: return Color(nsColor: Design.warningColor)
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 10) {
            pillButton(L("重置")) { vm.reset() }
            pillButton(L("检查更新")) { vm.checkForUpdates() }
            if dirty {
                Text(L("配置已修改"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Design.warningColor))
                    .fixedSize()
            }
            Spacer()
            pillButton(L("备份数据")) { vm.backupData() }
            Button { vm.save() } label: {
                Text(L("保存"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.backgroundDark))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: Design.successColor)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - 窗口控制器

class SettingsWindowController: NSWindowController {
    let settings: Settings
    let onSave: () -> Void

    init(settings: Settings, onSave: @escaping () -> Void) {
        self.settings = settings
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("ccBar 设置")
        window.minSize = NSSize(width: 560, height: 520)
        window.center()
        window.setFrameAutosaveName("CCBarSettings")
        window.backgroundColor = Design.backgroundDark

        super.init(window: window)

        let vm = SettingsViewModel(settings: settings) { [weak self] in
            self?.onSave()
            self?.window?.close()
        }
        window.contentViewController = NSHostingController(rootView: SettingsRootView(vm: vm))
    }

    required init?(coder: NSCoder) { fatalError() }
}
