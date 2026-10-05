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
    @Published var theme: Theme = .default
    @Published var refreshIntervalText = ""
    @Published var warningThresholdText = ""
    @Published var notifyIntervalText = ""
    @Published var ledThresholdText = ""
    @Published var warningEnabled = true
    @Published var launchAtLogin = false
    @Published var menuPetEnabled = true
    @Published var menuEmojiEnabled = true
    @Published var popoverWide = false
    @Published var sources: [SourceRowDraft] = []

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
            sources[i].statusText = s
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
            sources[i].statusText = "文件不存在"
            sources[i].statusKind = .warn
        } else if let error = Self.validateDB(path: path, requiredTables: adapter.requiredTables) {
            sources[i].statusText = error
            sources[i].statusKind = .warn
        } else {
            sources[i].statusText = "表结构正确（保存后生效）"
            sources[i].statusKind = .ok
        }
    }

    static func validateDB(path: String, requiredTables: [String]) -> String? {
        var db: OpaquePointer?
        let escaped = path.replacingOccurrences(of: "'", with: "%27")
        guard sqlite3_open_v2("file:\(escaped)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return "打不开（被占用或损坏）"
        }
        defer { sqlite3_close_v2(db) }
        let list = requiredTables.joined(separator: "','")
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('\(list)')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "校验失败" }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) >= Int64(requiredTables.count) {
            return nil
        }
        return "缺少必需表"
    }

    /// 选择数据源库文件
    func browseSource(id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }),
              let adapter = SourceRegistry.adapter(for: id) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 \(adapter.name) 数据库文件"
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
        if interval == nil || !(5...3000).contains(interval!) { invalid.append("刷新间隔（5 ~ 3000 秒）") }
        let threshold = Int(warningThresholdText)
        if threshold == nil || threshold! <= 0 { invalid.append("预警阈值（正整数，万）") }
        let notify = Int(notifyIntervalText)
        if notify == nil || notify! < 0 { invalid.append("通知间隔（≥ 0 的整数，万，0=关闭）") }
        let led = Int(ledThresholdText)
        if led == nil || led! < 0 { invalid.append("红色门槛（≥ 0 的整数，万，0=不变红）") }
        if !invalid.isEmpty {
            showAlert("无法保存", "以下字段无效：\n" + invalid.joined(separator: "\n"))
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
        settings.notifyInterval = notify!
        settings.ledRedThreshold = led!
        applyTheme(theme)

        showAlert("设置已保存", "新的设置将在下次刷新时生效")
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
            showAlert("备份完成",
                      "统计库已备份到：\n\(url.path)\n\n恢复方式：退出 ccBar 后用备份文件替换\n~/Library/Application Support/ccbar/ccbar.db")
        } else {
            showAlert("备份失败", "统计库未打开或目标位置不可写")
        }
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
            if vm.theme == .crt {
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
            Text("设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color(nsColor: Design.textPrimary))
        }
        .frame(height: 24)

        sep

        // 主题选择
        HStack(spacing: 6) {
            Image(systemName: "paintpalette")
                .foregroundColor(Color(nsColor: Design.brandColor))
                .frame(width: 16, height: 16)
            labelText("主题风格")
            Circle()
                .fill(Color(nsColor: vm.theme.accent))
                .frame(width: 8, height: 8)
            Picker("", selection: $vm.theme) {
                ForEach(Theme.allCases, id: \.self) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Spacer()
        }
        .frame(height: 24)

        settingRow(icon: "arrow.clockwise", label: "刷新间隔",
                   text: $vm.refreshIntervalText, unit: "秒", hint: "5 ~ 3000")

        // 数据源（每源一行：启用勾选 + 路径 + 浏览）
        Text("数据源")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(nsColor: Design.textMuted))
        ForEach($vm.sources) { $row in
            sourceRow($row)
        }

        settingRow(icon: "exclamationmark.triangle", label: "预警阈值",
                   text: $vm.warningThresholdText, unit: "万", hint: "超出时通知")
        settingRow(icon: "bell.badge", label: "通知间隔",
                   text: $vm.notifyIntervalText, unit: "万", hint: "每累计N万通知，0=关闭")
        settingRow(icon: "bolt.badge.automatic", label: "红色门槛",
                   text: $vm.ledThresholdText, unit: "万", hint: "单次刷新增量达到变红，0=不变红")

        sep

        Toggle(" 启用用量预警", isOn: $vm.warningEnabled)
        Toggle(" 开机自动启动", isOn: $vm.launchAtLogin)
        Toggle(" 菜单栏动画伴侣（小猫随用量跑动）", isOn: $vm.menuPetEnabled)
        Toggle(" 菜单栏表情分级（🙂→🥵）", isOn: $vm.menuEmojiEnabled)
        Toggle(" 宽版弹窗（380pt）", isOn: $vm.popoverWide)

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
                Button("浏览") {
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
            Button("重置") { vm.reset() }
            Button("检查更新") { vm.checkForUpdates() }
            Button("备份数据") { vm.backupData() }
            Button("保存") { vm.save() }
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
        window.title = "ccBar 设置"
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
