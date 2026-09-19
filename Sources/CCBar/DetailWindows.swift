import Cocoa
import SQLite3

// MARK: - 设置窗口

class SettingsWindowController: NSWindowController {
    let settings: Settings
    let onSave: () -> Void
    var intervalField: NSTextField!
    var pathField: NSTextField!
    var warningField: NSTextField!
    var warningCheck: NSButton!
    var launchCheck: NSButton!
    var themePopup: NSPopUpButton!

    init(settings: Settings, onSave: @escaping () -> Void) {
        self.settings = settings
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ccBar 设置"
        window.center()
        window.backgroundColor = Design.backgroundDark

        // 毛玻璃背景
        let blur = NSVisualEffectView(frame: window.contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        window.contentView!.addSubview(blur)

        super.init(window: window)
        setupUI()
        loadSettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setupUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])

        // 标题行
        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.brandColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        titleRow.addSubview(icon)
        let title = NSTextField(labelWithString: "设置")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = Design.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(title)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor)
        ])
        titleRow.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(titleRow)

        addSep(to: stack)

        // 主题选择
        let themeRow = makeThemeRow()
        stack.addArrangedSubview(themeRow)
        themeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 刷新间隔
        intervalField = makeField()
        let intervalRow = makeSettingRow(label: "刷新间隔", sfIcon: "arrow.clockwise",
                                         unit: "秒", field: intervalField, hint: "5 ~ 3000")
        stack.addArrangedSubview(intervalRow)
        intervalRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 数据库路径
        pathField = makeField()
        pathField.lineBreakMode = .byTruncatingMiddle
        let pathRow = makePathRow()
        stack.addArrangedSubview(pathRow)
        pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 预警阈值
        warningField = makeField()
        let warningRow = makeSettingRow(label: "预警阈值", sfIcon: "exclamationmark.triangle",
                                         unit: "万", field: warningField, hint: "超出时通知")
        stack.addArrangedSubview(warningRow)
        warningRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        addSep(to: stack)

        // 复选框
        warningCheck = NSButton(checkboxWithTitle: " 启用用量预警", target: nil, action: nil)
        warningCheck.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(warningCheck)

        launchCheck = NSButton(checkboxWithTitle: " 开机自动启动", target: nil, action: nil)
        launchCheck.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(launchCheck)

        addSep(to: stack)

        // 按钮栏
        let buttonBar = NSStackView()
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 10
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttonBar)
        buttonBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        let resetBtn = makeButton(title: "重置", action: #selector(resetSettings))
        buttonBar.addArrangedSubview(resetBtn)

        let saveBtn = makeButton(title: "保存", action: #selector(saveSettings))
        saveBtn.keyEquivalent = "\r"
        saveBtn.bezelStyle = .rounded
        buttonBar.addArrangedSubview(saveBtn)
    }

    private func makeField() -> NSTextField {
        let f = NSTextField()
        f.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        f.textColor = Design.textPrimary
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return f
    }

    private func makeSettingRow(label: String, sfIcon: String, unit: String, field: NSTextField, hint: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: sfIcon, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addSubview(icon)

        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        lbl.textColor = Design.textPrimary
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        row.addSubview(field)

        let unitLbl = NSTextField(labelWithString: unit)
        unitLbl.font = NSFont.systemFont(ofSize: 12)
        unitLbl.textColor = Design.textMuted
        unitLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(unitLbl)

        let hintLbl = NSTextField(labelWithString: hint)
        hintLbl.font = NSFont.systemFont(ofSize: 11)
        hintLbl.textColor = Design.textMuted
        hintLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hintLbl)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.widthAnchor.constraint(equalToConstant: 70),
            field.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            unitLbl.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            unitLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            hintLbl.leadingAnchor.constraint(equalTo: unitLbl.trailingAnchor, constant: 8),
            hintLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    private func makeThemeRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.brandColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addSubview(icon)

        let lbl = NSTextField(labelWithString: "主题风格")
        lbl.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        lbl.textColor = Design.textPrimary
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        themePopup = NSPopUpButton()
        themePopup.translatesAutoresizingMaskIntoConstraints = false
        for theme in Theme.allCases {
            themePopup.addItem(withTitle: theme.displayName)
            // 给每个菜单项加颜色圆点
            if let item = themePopup.lastItem {
                let colorImage = NSImage(size: NSSize(width: 12, height: 12))
                colorImage.lockFocus()
                theme.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8)).fill()
                colorImage.unlockFocus()
                colorImage.isTemplate = false
                item.image = colorImage
            }
        }
        themePopup.selectItem(withTitle: Theme.current.displayName)
        row.addSubview(themePopup)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.widthAnchor.constraint(equalToConstant: 70),
            themePopup.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
            themePopup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            themePopup.widthAnchor.constraint(equalToConstant: 120)
        ])
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    private func makePathRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addSubview(icon)

        let lbl = NSTextField(labelWithString: "数据库")
        lbl.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        lbl.textColor = Design.textPrimary
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        row.addSubview(pathField)

        let browseBtn = NSButton(title: "浏览", target: self, action: #selector(browsePath))
        browseBtn.bezelStyle = .rounded
        browseBtn.font = NSFont.systemFont(ofSize: 12)
        browseBtn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(browseBtn)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.widthAnchor.constraint(equalToConstant: 70),
            pathField.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
            pathField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pathField.trailingAnchor.constraint(equalTo: browseBtn.leadingAnchor, constant: -8),
            browseBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            browseBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            browseBtn.widthAnchor.constraint(equalToConstant: 60)
        ])
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 13)
        return btn
    }

    private func addSep(to stack: NSStackView) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.borderColor = Design.separatorColor
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func loadSettings() {
        intervalField.stringValue = "\(settings.refreshInterval)"
        pathField.stringValue = settings.dbPath
        pathField.toolTip = settings.dbPath
        warningField.stringValue = "\(settings.warningThreshold)"
        warningCheck.state = settings.warningEnabled ? .on : .off
        launchCheck.state = settings.launchAtLogin ? .on : .off
        themePopup.selectItem(withTitle: Theme.current.displayName)
    }

    @objc func browsePath() {
        let panel = NSOpenPanel()
        panel.title = "选择数据库文件"
        panel.allowedFileTypes = ["db"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] result in
            if result == .OK, let url = panel.url {
                self?.pathField.stringValue = url.path
                self?.pathField.toolTip = url.path
            }
        }
    }

    @objc func saveSettings() {
        if let interval = Int(intervalField.stringValue), interval >= 5 && interval <= 3000 {
            settings.refreshInterval = interval
        }
        settings.dbPath = pathField.stringValue
        if let threshold = Int(warningField.stringValue), threshold > 0 {
            settings.warningThreshold = threshold
        }
        settings.warningEnabled = warningCheck.state == .on
        settings.launchAtLogin = launchCheck.state == .on

        // 保存主题
        let selectedTheme = Theme.allCases.first { $0.displayName == themePopup.titleOfSelectedItem } ?? .default
        Theme.current = selectedTheme

        let alert = NSAlert()
        alert.messageText = "设置已保存"
        alert.informativeText = "新的设置将在下次刷新时生效"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()

        onSave()
        window?.close()
    }

    @objc func resetSettings() {
        settings.refreshInterval = 30
        settings.dbPath = "\(NSHomeDirectory())/.cc-switch/cc-switch.db"
        settings.warningThreshold = 50
        settings.warningEnabled = true
        settings.launchAtLogin = false
        loadSettings()
    }
}

// MARK: - 通用详情窗口基类

class DetailBaseWindowController: NSWindowController {
    var contentStack: NSStackView!
    var dateLabel: NSTextField!

    func setupBaseUI(navTarget: AnyObject?, prevAction: Selector?, nextAction: Selector?) {
        guard let contentView = window?.contentView else { return }

        // 毛玻璃
        let blur = NSVisualEffectView(frame: contentView.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        contentView.addSubview(blur)

        // 导航栏
        let navBar = NSView()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(navBar)

        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            navBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            navBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            navBar.heightAnchor.constraint(equalToConstant: 30)
        ])

        if let prevAction = prevAction {
            let prevBtn = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上一个") ?? NSImage(),
                                   target: navTarget, action: prevAction)
            prevBtn.bezelStyle = .inline
            prevBtn.isBordered = false
            prevBtn.translatesAutoresizingMaskIntoConstraints = false
            navBar.addSubview(prevBtn)
            prevBtn.leadingAnchor.constraint(equalTo: navBar.leadingAnchor).isActive = true
            prevBtn.centerYAnchor.constraint(equalTo: navBar.centerYAnchor).isActive = true
        }

        dateLabel = NSTextField(labelWithString: "")
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        dateLabel.textColor = Design.textPrimary
        dateLabel.alignment = .center
        navBar.addSubview(dateLabel)
        dateLabel.centerXAnchor.constraint(equalTo: navBar.centerXAnchor).isActive = true
        dateLabel.centerYAnchor.constraint(equalTo: navBar.centerYAnchor).isActive = true

        if let nextAction = nextAction {
            let nextBtn = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "下一个") ?? NSImage(),
                                   target: navTarget, action: nextAction)
            nextBtn.bezelStyle = .inline
            nextBtn.isBordered = false
            nextBtn.translatesAutoresizingMaskIntoConstraints = false
            navBar.addSubview(nextBtn)
            nextBtn.trailingAnchor.constraint(equalTo: navBar.trailingAnchor).isActive = true
            nextBtn.centerYAnchor.constraint(equalTo: navBar.centerYAnchor).isActive = true
        }

        // 内容栈
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: navBar.bottomAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    // 通用表格行
    func makeTableRow(columns: [(text: String, width: CGFloat, bold: Bool, color: NSColor)]) -> NSView {
        let row = InteractiveRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true

        var leading = row.leadingAnchor
        for (i, col) in columns.enumerated() {
            let field = NSTextField(labelWithString: col.text)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = NSFont.monospacedDigitSystemFont(ofSize: col.bold ? 12 : 11,
                                                           weight: col.bold ? .bold : .medium)
            field.textColor = col.color
            field.alignment = i == 0 ? .left : .right
            row.addSubview(field)

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leading, constant: i == 0 ? 0 : 8),
                field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                field.widthAnchor.constraint(equalToConstant: col.width)
            ])
            leading = field.trailingAnchor
        }
        return row
    }

    func makeTableHeader(labels: [String], widths: [CGFloat]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true

        var leading = row.leadingAnchor
        for (i, text) in labels.enumerated() {
            let label = NSTextField(labelWithString: text)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = Design.textMuted
            label.alignment = i == 0 ? .left : .right
            row.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leading, constant: i == 0 ? 0 : 8),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: widths[i])
            ])
            leading = label.trailingAnchor
        }
        return row
    }

    func makeSep() -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        sep.borderColor = Design.separatorColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return sep
    }

    func makeTotalRow(columns: [(text: String, width: CGFloat)]) -> NSView {
        return makeTableRow(columns: columns.map {
            (text: $0.text, width: $0.width, bold: true, color: Design.textPrimary)
        })
    }

    func fmtNum(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        else if n >= 10_000 { return "\(n / 10_000)万" }
        else if n == 0 { return "-" }
        else { return "\(n)" }
    }

    func addSparkline(container: NSView, values: [CGFloat], hueOffset: CGFloat = 0) {
        let sparkline = SparklineView(frame: .zero)
        sparkline.values = values
        sparkline.useGradient = true
        sparkline.hueOffset = hueOffset
        sparkline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sparkline)
        NSLayoutConstraint.activate([
            sparkline.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            sparkline.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            sparkline.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            sparkline.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
    }
}

// MARK: - 7天详情窗口

class DetailWindowController: DetailBaseWindowController {
    var currentWeekStart: Date = Date()
    var onDateChange: ((Date) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "近7天用量"
        window.center()
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 420, height: 250)
        self.init(window: window)
        setupBaseUI(navTarget: self, prevAction: #selector(prevWeek), nextAction: #selector(nextWeek))
    }

    @objc func prevWeek() {
        currentWeekStart = Calendar.current.date(byAdding: .day, value: -7, to: currentWeekStart)!
        onDateChange?(currentWeekStart)
    }

    @objc func nextWeek() {
        let next = Calendar.current.date(byAdding: .day, value: 7, to: currentWeekStart)!
        if next <= Date() { currentWeekStart = next; onDateChange?(next) }
    }

    func reloadData(db: OpaquePointer?, weekStart: Date) {
        guard let db = db else { return }
        currentWeekStart = weekStart

        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd"
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        dateLabel.stringValue = "\(fmt.string(from: weekStart))  ~  \(fmt.string(from: end))"

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // sparkline 容器
        let chartBox = NSView()
        chartBox.translatesAutoresizingMaskIntoConstraints = false
        chartBox.heightAnchor.constraint(equalToConstant: 54).isActive = true
        contentStack.addArrangedSubview(chartBox)
        chartBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        contentStack.addArrangedSubview(makeSep())

        let widths: [CGFloat] = [70, 65, 95, 95]
        contentStack.addArrangedSubview(makeTableHeader(labels: ["日期", "请求", "总 Token", "缓存读"], widths: widths))
        contentStack.addArrangedSubview(makeSep())

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var totalReqs = 0; var totalToken: Int64 = 0; var totalCache: Int64 = 0
        var dailyTokens: [CGFloat] = []

        for d in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: d, to: weekStart) else { continue }
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: today).day ?? 0
            let (reqs, token, cache) = queryDay(db: db, daysAgo: daysAgo)
            totalReqs += reqs; totalToken += token; totalCache += cache

            let color: NSColor = token == 0 ? Design.textMuted : Design.dataHighlightColor
            let row = makeTableRow(columns: [
                (fmt.string(from: date), widths[0], false, color),
                (reqs == 0 ? "-" : "\(reqs)", widths[1], false, reqs == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(token), widths[2], false, token == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(cache), widths[3], false, cache == 0 ? Design.textMuted : Design.textSecondary)
            ])
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            dailyTokens.append(CGFloat(token))
        }

        // sparkline
        let weekOf = cal.ordinality(of: .weekOfYear, in: .year, for: weekStart) ?? 0
        addSparkline(container: chartBox, values: dailyTokens, hueOffset: CGFloat(weekOf % 8) / 8.0)

        contentStack.addArrangedSubview(makeSep())
        let totalRow = makeTotalRow(columns: [
            ("合计", widths[0]), ("\(totalReqs)", widths[1]),
            (fmtNum(totalToken), widths[2]), (fmtNum(totalCache), widths[3])
        ])
        contentStack.addArrangedSubview(totalRow)
        totalRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func queryDay(db: OpaquePointer, daysAgo: Int) -> (Int, Int64, Int64) {
        let sql = """
        SELECT SUM(r), SUM(o), SUM(c) FROM (
            SELECT COUNT(*) as r, COALESCE(SUM(output_tokens+input_tokens+cache_read_tokens),0) as o,
                COALESCE(SUM(cache_read_tokens),0) as c
            FROM proxy_request_logs WHERE date(created_at,'unixepoch','localtime')=date('now','localtime','-'||?||' days')
            UNION ALL
            SELECT COALESCE(SUM(request_count),0), COALESCE(SUM(output_tokens+input_tokens+cache_read_tokens),0),
                COALESCE(SUM(cache_read_tokens),0)
            FROM usage_daily_rollups WHERE date=date('now','localtime','-'||?||' days')
                AND date<(SELECT date(MIN(created_at),'unixepoch','localtime') FROM proxy_request_logs)
        )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0,0,0) }
        sqlite3_bind_int(stmt, 1, Int32(daysAgo))
        sqlite3_bind_int(stmt, 2, Int32(daysAgo))
        var result = (0, Int64(0), Int64(0))
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = (Int(sqlite3_column_int(stmt, 0)), sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2))
        }
        sqlite3_finalize(stmt)
        return result
    }
}

// MARK: - 30天详情窗口

class MonthDetailWindowController: DetailBaseWindowController {
    var currentMonth: Date = Date()
    var db: OpaquePointer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "近30天用量"
        window.center()
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 420, height: 300)
        self.init(window: window)
        setupBaseUI(navTarget: self, prevAction: #selector(prevMonth), nextAction: #selector(nextMonth))
    }

    @objc func prevMonth() {
        currentMonth = Calendar.current.date(byAdding: .month, value: -1, to: currentMonth)!
        reloadData()
    }

    @objc func nextMonth() {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: currentMonth)!
        if next <= Date() { currentMonth = next; reloadData() }
    }

    func reloadData() {
        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM"
        dateLabel.stringValue = fmt.string(from: currentMonth)
        guard let db = self.db else { return }

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: currentMonth)
        let first = cal.date(from: comps)!
        let days = cal.range(of: .day, in: .month, for: currentMonth)!.count

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // 柱状图容器（比折线图高一些）
        let chartBox = NSView()
        chartBox.translatesAutoresizingMaskIntoConstraints = false
        chartBox.heightAnchor.constraint(equalToConstant: 70).isActive = true
        contentStack.addArrangedSubview(chartBox)
        chartBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.addArrangedSubview(makeSep())

        let widths: [CGFloat] = [70, 65, 95, 95]
        contentStack.addArrangedSubview(makeTableHeader(labels: ["日期", "请求", "总 Token", "缓存读"], widths: widths))
        contentStack.addArrangedSubview(makeSep())

        let today = cal.startOfDay(for: Date())
        var totalReqs = 0; var totalToken: Int64 = 0; var totalCache: Int64 = 0
        var dailyTokens: [CGFloat] = []

        for day in 1...days {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: first) else { continue }
            if cal.startOfDay(for: date) > today { break }
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: today).day ?? 0
            let (reqs, token, cache) = queryDay(db: db, daysAgo: daysAgo)
            totalReqs += reqs; totalToken += token; totalCache += cache

            let color: NSColor = token == 0 ? Design.textMuted : Design.dataHighlightColor
            let dateStr = String(format: "%02d/%02d", comps.month!, day)
            let row = makeTableRow(columns: [
                (dateStr, widths[0], false, color),
                (reqs == 0 ? "-" : "\(reqs)", widths[1], false, reqs == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(token), widths[2], false, token == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(cache), widths[3], false, cache == 0 ? Design.textMuted : Design.textSecondary)
            ])
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            dailyTokens.append(CGFloat(token))
        }

        // 柱状图（每根柱子用渐变色，和折线图配色一致）
        let barChart = BarChartView(frame: .zero)
        barChart.values = dailyTokens
        barChart.labels = (1...days).map { String(format: "%02d", $0) }
        barChart.barColor = Design.brandColor  // 基础色（会被渐变覆盖）
        barChart.useGradient = true
        barChart.hueOffset = CGFloat(((comps.month ?? 1) * 3) % 8) / 8.0
        barChart.translatesAutoresizingMaskIntoConstraints = false
        chartBox.addSubview(barChart)
        NSLayoutConstraint.activate([
            barChart.topAnchor.constraint(equalTo: chartBox.topAnchor, constant: 4),
            barChart.leadingAnchor.constraint(equalTo: chartBox.leadingAnchor, constant: 6),
            barChart.trailingAnchor.constraint(equalTo: chartBox.trailingAnchor, constant: -6),
            barChart.bottomAnchor.constraint(equalTo: chartBox.bottomAnchor, constant: -4)
        ])

        contentStack.addArrangedSubview(makeSep())
        let totalRow = makeTotalRow(columns: [
            ("合计", widths[0]), ("\(totalReqs)", widths[1]),
            (fmtNum(totalToken), widths[2]), (fmtNum(totalCache), widths[3])
        ])
        contentStack.addArrangedSubview(totalRow)
        totalRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func queryDay(db: OpaquePointer, daysAgo: Int) -> (Int, Int64, Int64) {
        let sql = """
        SELECT SUM(r), SUM(o), SUM(c) FROM (
            SELECT COUNT(*) as r, COALESCE(SUM(output_tokens+input_tokens+cache_read_tokens),0) as o,
                COALESCE(SUM(cache_read_tokens),0) as c
            FROM proxy_request_logs WHERE date(created_at,'unixepoch','localtime')=date('now','localtime','-'||?||' days')
            UNION ALL
            SELECT COALESCE(SUM(request_count),0), COALESCE(SUM(output_tokens+input_tokens+cache_read_tokens),0),
                COALESCE(SUM(cache_read_tokens),0)
            FROM usage_daily_rollups WHERE date=date('now','localtime','-'||?||' days')
                AND date<(SELECT date(MIN(created_at),'unixepoch','localtime') FROM proxy_request_logs)
        )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0,0,0) }
        sqlite3_bind_int(stmt, 1, Int32(daysAgo)); sqlite3_bind_int(stmt, 2, Int32(daysAgo))
        var result = (0, Int64(0), Int64(0))
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = (Int(sqlite3_column_int(stmt, 0)), sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2))
        }
        sqlite3_finalize(stmt)
        return result
    }
}

// MARK: - 模型分布详情窗口

class ModelDetailWindowController: DetailBaseWindowController {
    var currentDate: Date = Date()
    var onDateChange: ((Date) -> Void)?
    var db: OpaquePointer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "模型分布详情"
        window.center()
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 460, height: 300)
        self.init(window: window)
        setupBaseUI(navTarget: self, prevAction: #selector(prevDay), nextAction: #selector(nextDay))
    }

    @objc func prevDay() {
        currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate)!
        onDateChange?(currentDate)
    }
    @objc func nextDay() {
        let t = Calendar.current.date(byAdding: .day, value: 1, to: currentDate)!
        if t <= Date() { currentDate = t; onDateChange?(t) }
    }

    func reloadData(db: OpaquePointer?, date: Date) {
        guard let db = db else { return }
        currentDate = date
        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd"
        dateLabel.stringValue = fmt.string(from: date)

        let cal = Calendar.current
        let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0

        let sql = """
        SELECT model, COUNT(*),
            COALESCE(SUM(input_tokens+output_tokens+cache_read_tokens+cache_creation_tokens),0),
            COALESCE(SUM(cache_read_tokens),0)
        FROM proxy_request_logs
        WHERE date(created_at,'unixepoch','localtime')=date('now','localtime','-'||?||' days')
        GROUP BY model ORDER BY 3 DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int(stmt, 1, Int32(daysAgo))
        var models: [(String, Int, Int64, Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            models.append((String(cString: sqlite3_column_text(stmt, 0)),
                          Int(sqlite3_column_int(stmt, 1)),
                          sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3)))
        }
        sqlite3_finalize(stmt)

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if models.isEmpty {
            let lbl = NSTextField(labelWithString: "暂无数据")
            lbl.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            lbl.textColor = Design.textMuted
            contentStack.addArrangedSubview(lbl)
            return
        }

        let totalToken = models.reduce(Int64(0)) { $0 + $1.2 }

        // 环形图
        let chartBox = NSView()
        chartBox.translatesAutoresizingMaskIntoConstraints = false
        chartBox.heightAnchor.constraint(equalToConstant: 140).isActive = true
        contentStack.addArrangedSubview(chartBox)
        chartBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let colors = Design.modelColors()
        let donut = DonutChartWithLegendView(frame: .zero)
        donut.items = models.prefix(6).enumerated().map { i, m in
            let pct = totalToken > 0 ? String(format: "%.1f%%", Double(m.2) / Double(totalToken) * 100) : "0%"
            let short = shortModelName(m.0)
            return DonutChartWithLegendView.Item(value: CGFloat(m.2), color: colors[i % colors.count], label: short, percentage: pct)
        }
        donut.translatesAutoresizingMaskIntoConstraints = false
        chartBox.addSubview(donut)
        NSLayoutConstraint.activate([
            donut.topAnchor.constraint(equalTo: chartBox.topAnchor),
            donut.leadingAnchor.constraint(equalTo: chartBox.leadingAnchor),
            donut.trailingAnchor.constraint(equalTo: chartBox.trailingAnchor),
            donut.bottomAnchor.constraint(equalTo: chartBox.bottomAnchor)
        ])

        contentStack.addArrangedSubview(makeSep())

        let widths: [CGFloat] = [160, 65, 100, 100]
        contentStack.addArrangedSubview(makeTableHeader(labels: ["模型", "请求", "总 Token", "缓存读"], widths: widths))
        contentStack.addArrangedSubview(makeSep())

        var totR = 0; var totT: Int64 = 0; var totC: Int64 = 0
        for m in models {
            totR += m.1; totT += m.2; totC += m.3
            let color: NSColor = m.2 == 0 ? Design.textMuted : Design.dataHighlightColor
            let row = makeTableRow(columns: [
                (shortModelName(m.0), widths[0], false, color),
                (m.1 == 0 ? "-" : "\(m.1)", widths[1], false, m.1 == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(m.2), widths[2], false, m.2 == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(m.3), widths[3], false, m.3 == 0 ? Design.textMuted : Design.textSecondary)
            ])
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        contentStack.addArrangedSubview(makeSep())
        let totalRow = makeTotalRow(columns: [
            ("合计", widths[0]), ("\(totR)", widths[1]),
            (fmtNum(totT), widths[2]), (fmtNum(totC), widths[3])
        ])
        contentStack.addArrangedSubview(totalRow)
        totalRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func shortModelName(_ name: String) -> String {
        var s = name.lowercased()
        if let r = s.range(of: "-", options: .backwards) {
            let after = s[r.upperBound...]
            if after.count == 8, Int(after) != nil { s = String(s[..<r.lowerBound]) }
        }
        for p in ["claude-", "openai-", "deepseek-", "google-"] {
            if s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        }
        if s.count > 18 { s = String(s.prefix(18)) + "…" }
        return s
    }
}

// MARK: - 每小时详情窗口

class HourlyDetailWindowController: DetailBaseWindowController {
    var currentDate: Date = Date()
    var onDateChange: ((Date) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "每小时用量"
        window.center()
        window.backgroundColor = Design.backgroundDark
        window.minSize = NSSize(width: 360, height: 300)
        self.init(window: window)
        setupBaseUI(navTarget: self, prevAction: #selector(prevDay), nextAction: #selector(nextDay))
    }

    @objc func prevDay() {
        currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate)!
        onDateChange?(currentDate)
    }
    @objc func nextDay() {
        let t = Calendar.current.date(byAdding: .day, value: 1, to: currentDate)!
        if t <= Date() { currentDate = t; onDateChange?(t) }
    }

    func reloadData(db: OpaquePointer?, date: Date) {
        guard let db = db else { return }
        currentDate = date
        let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd"
        dateLabel.stringValue = fmt.string(from: date)

        let cal = Calendar.current
        let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0

        var hourly: [(Int, Int64, Int64, Int64)] = Array(repeating: (0, 0, 0, 0), count: 24)
        let sql = """
        SELECT strftime('%H',created_at,'unixepoch','localtime'), COUNT(*),
            COALESCE(SUM(output_tokens+input_tokens),0), COALESCE(SUM(cache_read_tokens),0)
        FROM proxy_request_logs
        WHERE date(created_at,'unixepoch','localtime')=date('now','localtime','-'||?||' days')
        GROUP BY 1 ORDER BY 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int(stmt, 1, Int32(daysAgo))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let hs = sqlite3_column_text(stmt, 0) {
                let h = Int(String(cString: hs)) ?? 0
                if h >= 0 && h < 24 {
                    hourly[h] = (Int(sqlite3_column_int(stmt, 1)), sqlite3_column_int64(stmt, 2),
                                sqlite3_column_int64(stmt, 3), 0)
                }
            }
        }
        sqlite3_finalize(stmt)

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // 找有数据的小时范围
        var start = 23, end = 0
        for h in 0..<24 {
            if hourly[h].0 > 0 || hourly[h].1 > 0 {
                if h < start { start = h }; if h > end { end = h }
            }
        }
        if start > end {
            let lbl = NSTextField(labelWithString: "暂无数据")
            lbl.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            lbl.textColor = Design.textMuted
            contentStack.addArrangedSubview(lbl)
            return
        }

        // 柱状图
        let chartBox = NSView()
        chartBox.translatesAutoresizingMaskIntoConstraints = false
        chartBox.heightAnchor.constraint(equalToConstant: 80).isActive = true
        contentStack.addArrangedSubview(chartBox)
        chartBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let barChart = BarChartView(frame: .zero)
        barChart.values = hourly.map { CGFloat($0.1) }  // 用 output+input 作为柱高
        barChart.labels = (0..<24).map { "\($0)" }
        barChart.barColor = Design.brandColor
        barChart.translatesAutoresizingMaskIntoConstraints = false
        chartBox.addSubview(barChart)
        NSLayoutConstraint.activate([
            barChart.topAnchor.constraint(equalTo: chartBox.topAnchor, constant: 4),
            barChart.leadingAnchor.constraint(equalTo: chartBox.leadingAnchor, constant: 8),
            barChart.trailingAnchor.constraint(equalTo: chartBox.trailingAnchor, constant: -8),
            barChart.bottomAnchor.constraint(equalTo: chartBox.bottomAnchor, constant: -4)
        ])

        contentStack.addArrangedSubview(makeSep())

        let widths: [CGFloat] = [50, 65, 100, 100]
        contentStack.addArrangedSubview(makeTableHeader(labels: ["时间", "请求", "总 Token", "缓存读"], widths: widths))
        contentStack.addArrangedSubview(makeSep())

        // 合计
        var totR = 0; var totT: Int64 = 0; var totC: Int64 = 0
        for h in start...end {
            let d = hourly[h]; totR += d.0; totT += d.1; totC += d.2
        }
        let totalRow = makeTotalRow(columns: [
            ("合计", widths[0]), ("\(totR)", widths[1]),
            (fmtNum(totT), widths[2]), (fmtNum(totC), widths[3])
        ])
        contentStack.addArrangedSubview(totalRow)
        totalRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.addArrangedSubview(makeSep())

        for h in start...end {
            let d = hourly[h]
            let color: NSColor = d.1 == 0 ? Design.textMuted : Design.dataHighlightColor
            let row = makeTableRow(columns: [
                ("\(h)时", widths[0], false, color),
                (d.0 == 0 ? "-" : "\(d.0)", widths[1], false, d.0 == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(d.1), widths[2], false, d.1 == 0 ? Design.textMuted : Design.textPrimary),
                (fmtNum(d.2), widths[3], false, d.2 == 0 ? Design.textMuted : Design.textSecondary)
            ])
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let h = CGFloat(end - start + 2) * 24 + 100
        window?.setContentSize(NSSize(width: 440, height: min(h, 650)))
    }
}
