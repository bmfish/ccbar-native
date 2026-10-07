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
    @Published var warningEnabled = true
    @Published var launchAtLogin = false
    @Published var menuPetEnabled = true
    @Published var menuEmojiEnabled = true
    @Published var popoverWide = false
    @Published var autoWeeklyReport = true
    @Published var sources: [SourceRowDraft] = []
    @Published var language: AppLanguage = .system
    @Published var lastBackupDate = ""

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
        warningEnabled = settings.warningEnabled
        launchAtLogin = settings.launchAtLogin
        menuPetEnabled = settings.menuPetEnabled
        menuEmojiEnabled = settings.menuEmojiEnabled
        popoverWide = settings.popoverWide
        autoWeeklyReport = settings.autoWeeklyReport
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
        refreshSourceStatus()
    }

    // MARK: 数据源状态与路径校验

    /// 数据源连接状态（来自 StatsStore.attach 的诊断信息）
    func refreshSourceStatus() {
        let statuses = AppDelegate.shared?.store.sourceStatus ?? [:]
        for i in sources.indices {
            let s = statuses[sources[i].id] ?? ""
            sources[i].statusText = L(s)
            if s.contains("已连接") {
                sources[i].statusKind = .ok
            } else if s == "未启用" {
                sources[i].statusKind = .muted
            } else {
                sources[i].statusKind = .warn
            }
        }
    }

    /// 只读试开一次源库并检查必需表，结果就地显示在状态行（不重建连接，保存时才生效）
    func validateSource(id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
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
        if !invalid.isEmpty {
            showAlert(L("无法保存"), L("以下字段无效：") + "\n" + invalid.joined(separator: "\n"))
            return
        }

        settings.refreshInterval = interval!
        // 数据源：勾选状态 + 路径（留空回落默认路径）
        settings.sourceConfigs = sources.map { row in
            let path = row.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return SourceConfig(id: row.id, enabled: row.enabled,
                                dbPath: path.isEmpty ? row.defaultPath : path)
        }
        settings.warningThreshold = threshold!
        settings.warningEnabled = warningEnabled
        applyLaunchAtLogin(launchAtLogin)
        settings.menuPetEnabled = menuPetEnabled
        settings.menuEmojiEnabled = menuEmojiEnabled
        settings.popoverWide = popoverWide
        settings.autoWeeklyReport = autoWeeklyReport
        settings.notifyInterval = notify!
        settings.ledRedThreshold = led!
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
        settings.autoWeeklyReport = true
        settings.ledRedThreshold = 100
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

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(nsColor: Design.backgroundDark).opacity(0.8))
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                }
                Rectangle().fill(Color(nsColor: Design.separatorColor)).frame(height: 1)
                buttonBar
            }
            if vm.theme.scanlines {
                ScanlineShape().allowsHitTesting(false)
            }
        }
        .frame(minWidth: 440, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        // 标题
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .foregroundColor(Color(nsColor: Design.brandColor))
                .frame(width: 20, height: 20)
            Text(L("设置"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color(nsColor: Design.textPrimary))
        }
        .frame(height: 24)

        sep

        // 主题选择（+ JSON 主题包导入/导出，方便分享）
        HStack(spacing: 6) {
            Image(systemName: "paintpalette")
                .foregroundColor(Color(nsColor: Design.brandColor))
                .frame(width: 16, height: 16)
            labelText(L("主题风格"))
            Circle()
                .fill(Color(nsColor: vm.theme.accent))
                .frame(width: 8, height: 8)
            Picker("", selection: $vm.theme) {
                ForEach(Theme.allThemes) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Button(L("导入")) { vm.importTheme() }
                .font(.system(size: 11))
            Button(L("导出")) { vm.exportTheme() }
                .font(.system(size: 11))
            if vm.themeIsCustom {
                Button(L("重命名")) { vm.renameTheme() }
                    .font(.system(size: 11))
                Button(L("删除")) { vm.deleteTheme() }
                    .font(.system(size: 11))
            }
            Spacer()
        }
        .frame(height: 24)

        settingRow(icon: "arrow.clockwise", label: L("刷新间隔"),
                   text: $vm.refreshIntervalText, unit: L("秒"), hint: "5 ~ 3000")

        // 数据源（每源一行：启用勾选 + 路径 + 浏览）
        Text(L("数据源"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(nsColor: Design.textMuted))
        ForEach($vm.sources) { $row in
            sourceRow($row)
        }

        settingRow(icon: "exclamationmark.triangle", label: L("预警阈值"),
                   text: $vm.warningThresholdText, unit: L("万"), hint: L("超出时通知"))
        settingRow(icon: "bell.badge", label: L("通知间隔"),
                   text: $vm.notifyIntervalText, unit: L("万"), hint: L("每累计N万通知，0=关闭"))

        // 界面语言（重启后生效）
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundColor(Color(nsColor: Design.textSecondary))
                .frame(width: 16, height: 16)
            labelText(L("界面语言"))
            Picker("", selection: $vm.language) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            Text(L("重启后生效"))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Spacer()
        }
        .frame(height: 24)
        settingRow(icon: "bolt.badge.automatic", label: L("红色门槛"),
                   text: $vm.ledThresholdText, unit: L("万"), hint: L("单次刷新增量达到变红，0=不变红"))

        sep

        Toggle(L("启用用量预警"), isOn: $vm.warningEnabled)
        Toggle(L("开机自动启动"), isOn: $vm.launchAtLogin)
        Toggle(L("菜单栏动画伴侣（小猫随用量跑动）"), isOn: $vm.menuPetEnabled)
        Toggle(L("菜单栏表情分级（🙂→🥵）"), isOn: $vm.menuEmojiEnabled)
        Toggle(L("宽版弹窗（380pt）"), isOn: $vm.popoverWide)
        Toggle(L("每周一自动生成用量周报"), isOn: $vm.autoWeeklyReport)

        // 自动备份状态（每天首次启动静默备份，滚动保留 7 份）
        HStack(spacing: 6) {
            Text(String(format: L("上次自动备份：%@"), vm.lastBackupDate))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Spacer()
            Button(L("打开备份目录")) { vm.openBackupFolder() }
                .font(.system(size: 11))
        }

        // 数据迁移（明细 CSV，导入幂等：主键去重，重复导零新增）
        HStack(spacing: 6) {
            Text(L("数据迁移（明细 CSV）"))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Spacer()
            Button(L("导入 CSV")) { vm.importData() }
                .font(.system(size: 11))
            Button(L("导出 CSV")) { vm.exportData() }
                .font(.system(size: 11))
        }

        sep
    }

    private var sep: some View {
        Rectangle()
            .fill(Color(nsColor: Design.separatorColor))
            .frame(height: 1)
    }

    private func labelText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Color(nsColor: Design.textPrimary))
            .frame(width: 70, alignment: .leading)
    }

    private func settingRow(icon: String, label: String, text: Binding<String>,
                            unit: String, hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(Color(nsColor: Design.textSecondary))
                .frame(width: 16, height: 16)
            labelText(label)
            numberField(text)
            Text(unit)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: Design.textMuted))
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Design.textMuted))
                .lineLimit(1)
            Spacer()
        }
        .frame(height: 24)
    }

    private func numberField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(Color(nsColor: Design.textPrimary))
            .padding(.horizontal, 6)
            .frame(width: 120)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: Design.backgroundDark).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: Design.separatorColor).opacity(0.6)))
    }

    private func sourceRow(_ row: Binding<SourceRowDraft>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle("", isOn: row.enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text(row.wrappedValue.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(nsColor: Design.textPrimary))
                    .frame(width: 70, alignment: .leading)
                ZStack(alignment: .leading) {
                    if row.wrappedValue.path.isEmpty {
                        // 占位符 = 默认路径（prompt 变体不带 onEditingChanged，自绘）
                        Text(row.wrappedValue.defaultPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(nsColor: Design.textMuted))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 6)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: row.path,
                              onEditingChanged: { editing in
                                  if !editing { vm.validateSource(id: row.wrappedValue.id) }
                              }, onCommit: {})
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: Design.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: Design.backgroundDark).opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: Design.separatorColor).opacity(0.6)))
                .help(row.wrappedValue.path)
                Button(L("浏览")) {
                    vm.browseSource(id: row.wrappedValue.id)
                }
                .font(.system(size: 12))
                .frame(width: 60)
            }
            .frame(height: 24)
            Text(row.wrappedValue.statusText)
                .font(.system(size: 10))
                .foregroundColor(statusColor(row.wrappedValue.statusKind))
        }
    }

    private func statusColor(_ kind: SourceRowDraft.StatusKind) -> Color {
        switch kind {
        case .ok: return .green
        case .muted: return Color(nsColor: Design.textMuted)
        case .warn: return .orange
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 10) {
            Button(L("重置")) { vm.reset() }
            Button(L("检查更新")) { vm.checkForUpdates() }
            Button(L("备份数据")) { vm.backupData() }
            Button(L("保存")) { vm.save() }
                .font(.system(size: 13, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("ccBar 设置")
        window.minSize = NSSize(width: 440, height: 420)
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
