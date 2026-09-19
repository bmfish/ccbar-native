import Cocoa

// MARK: - Popover View Controller

class PopoverViewController: NSViewController {
    private var scrollView: NSScrollView!
    private var contentStack: NSStackView!

    override func loadView() {
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = Design.backgroundDark.cgColor

        // 毛玻璃背景
        let blur = NSVisualEffectView(frame: mainView.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        mainView.addSubview(blur)

        scrollView = NSScrollView(frame: mainView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalRuler = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        mainView.addSubview(scrollView)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 6, right: 14)

        let clipView = NSClipView()
        clipView.documentView = contentStack
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor)
        ])

        self.view = mainView
    }

    func refresh() {
        buildContent()
    }

    // MARK: - 构建内容

    private func buildContent() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let today = AppDelegate.shared?.queryDayStats(days: 0)
        let yesterday = AppDelegate.shared?.queryDayStats(days: 1)
        let week = AppDelegate.shared?.queryDayStats(days: 7)
        let month = AppDelegate.shared?.queryDayStats(days: 30)
        let total = AppDelegate.shared?.queryTotalStats()
        let models = AppDelegate.shared?.queryModelBreakdown()

        // 渐变顶部条
        let gradientBar = GradientHeaderView()
        gradientBar.translatesAutoresizingMaskIntoConstraints = false
        gradientBar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        contentStack.addArrangedSubview(gradientBar)
        gradientBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
        addSpacer(4)

        // 问候语
        let greeting = AppDelegate.shared?.greetings.randomElement() ?? "ccBar 用量统计"
        addCenteredLabel(greeting, size: 11, color: Design.textMuted)
        addSpacer(6)

        // 今日统计卡片
        if let today = today {
            buildTodayCard(today)
        }

        // 模型分布
        if let models = models, !models.isEmpty {
            buildModelSection(models)
        }

        // 时间段统计（颜色跟随主题）
        if yesterday != nil || week != nil || month != nil || total != nil {
            let tc = Theme.current.trendIconColors
            addSectionHeader("趋势")
            if let yesterday = yesterday {
                addStatRow(sfIcon: "calendar", iconColor: tc.yesterday,
                          title: "昨日", value: Design.formatTokens(yesterday.total),
                          action: #selector(AppDelegate.openHourlyDetailYesterday))
            }
            if let week = week {
                addStatRow(sfIcon: "chart.bar", iconColor: tc.week,
                          title: "近7天", value: Design.formatTokens(week.total),
                          action: #selector(AppDelegate.openDetail))
            }
            if let month = month {
                addStatRow(sfIcon: "calendar.badge.clock", iconColor: tc.month,
                          title: "近30天", value: Design.formatTokens(month.total),
                          action: #selector(AppDelegate.openMonthDetail))
            }
            if let total = total {
                addStatRow(sfIcon: "sum", iconColor: tc.total,
                          title: "历史总量", value: Design.formatTokens(total.total),
                          action: #selector(AppDelegate.openMonthDetail))
            }
        }

        addSpacer(6)
        addSeparator()
        addSpacer(4)

        // 操作按钮
        buildButtonBar()

        addSpacer(2)
    }

    // MARK: - 今日统计卡片

    private func buildTodayCard(_ today: (reqs: Int, input: Int64, output: Int64, cacheCreate: Int64, cacheRead: Int64, total: Int64)) {
        let card = makeCard()

        // 标题
        let header = makeHeaderRow(title: "今日用量", sfIcon: "chart.line.uptrend.xyaxis",
                                   action: #selector(AppDelegate.openHourlyDetailToday))
        card.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true

        // 大数字（用主题专属色、字号、字重、发光）
        let bigNum = NSTextField(labelWithString: Design.formatTokens(today.total))
        bigNum.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.current.bigNumberFontSize,
                                                        weight: Theme.current.bigNumberWeight)
        bigNum.textColor = Design.bigNumberColor
        let glow = NSShadow()
        glow.shadowColor = Design.bigNumberColor.withAlphaComponent(Theme.current.glowAlpha)
        glow.shadowBlurRadius = Theme.current.glowRadius
        glow.shadowOffset = .zero
        bigNum.shadow = glow
        card.addArrangedSubview(bigNum)
        addSpacer(4, to: card)

        // 三列统计行
        let totalInput = today.input + today.cacheCreate + today.cacheRead
        let cacheRate = totalInput > 0 ? Double(today.cacheRead) / Double(totalInput) * 100 : 0

        let statsRow = NSStackView()
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.translatesAutoresizingMaskIntoConstraints = false

        statsRow.addArrangedSubview(makeStatColumn(label: "请求数", value: "\(today.reqs)", color: Design.textPrimary))
        statsRow.addArrangedSubview(makeStatColumn(label: "缓存命中",
                                                   value: String(format: "%.0f%%", cacheRate),
                                                   color: cacheRate > 75 ? Design.successColor : Design.warningColor))
        if let hours = AppDelegate.shared?.queryWorkHours() {
            statsRow.addArrangedSubview(makeStatColumn(label: "工时", value: "\(hours)h", color: Design.textPrimary))
        }

        card.addArrangedSubview(statsRow)
        statsRow.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true

        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
        addSpacer(10)
    }

    // MARK: - 模型分布

    private func buildModelSection(_ models: [(model: String, input: Int64, output: Int64, total: Int64)]) {
        let card = makeCard()

        let header = makeHeaderRow(title: "模型分布", sfIcon: "cpu",
                                   action: #selector(AppDelegate.openModelDetailToday))
        card.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true

        let colors = Design.modelColors()
        let maxTotal = models.prefix(4).map { $0.total }.max() ?? 1

        for (i, model) in models.prefix(4).enumerated() {
            let row = makeModelBar(name: shortModelName(model.model), value: model.total,
                                   maxValue: maxTotal, color: colors[i % colors.count])
            card.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        }

        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
        addSpacer(8)
    }

    /// 缩短模型名：claude-sonnet-4-20250514 → sonnet-4
    private func shortModelName(_ name: String) -> String {
        var s = name.lowercased()
        // 去掉日期后缀 (YYYYMMDD)
        if let dashRange = s.range(of: "-", options: .backwards) {
            let after = s[dashRange.upperBound...]
            if after.count == 8, Int(after) != nil {
                s = String(s[..<dashRange.lowerBound])
            }
        }
        // 去掉常见前缀
        for prefix in ["claude-", "openai-", "deepseek-", "google-"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        // 截断过长名字
        if s.count > 14 {
            s = String(s.prefix(14)) + "…"
        }
        return s
    }

    // MARK: - 按钮栏

    private func buildButtonBar() {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        bar.addArrangedSubview(makeIconButton(sfSymbol: "doc.on.doc", label: "复制",
                                              action: #selector(AppDelegate.copyStats)))
        bar.addArrangedSubview(makeIconButton(sfSymbol: "arrow.clockwise", label: "刷新",
                                              action: #selector(AppDelegate.refreshData)))
        bar.addArrangedSubview(makeIconButton(sfSymbol: "gearshape", label: "设置",
                                              action: #selector(AppDelegate.openSettingsAndClose)))
        bar.addArrangedSubview(makeIconButton(sfSymbol: "xmark", label: "退出",
                                              action: #selector(AppDelegate.quit)))

        contentStack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }

    // MARK: - 组件工厂

    private func makeCard() -> NSStackView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = Design.cardFillDark.cgColor
        card.layer?.cornerRadius = Design.cardCornerRadius
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Design.cardBorderDark.cgColor
        card.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return card
    }

    private func makeHeaderRow(title: String, sfIcon: String, action: Selector) -> NSView {
        let container = InteractiveRowView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let icon = NSImageView(image: NSImage(systemSymbolName: sfIcon, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        container.addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Design.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let chevron = NSTextField(labelWithString: "›")
        chevron.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        chevron.textColor = Design.textMuted
        chevron.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        container.addGestureRecognizer(NSClickGestureRecognizer(target: AppDelegate.shared, action: action))
        return container
    }

    private func makeStatColumn(label: String, value: String, color: NSColor) -> NSView {
        let col = NSView()
        col.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        lbl.textColor = Design.textMuted
        lbl.alignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        col.addSubview(lbl)

        let val = NSTextField(labelWithString: value)
        val.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        val.textColor = color
        val.alignment = .center
        val.translatesAutoresizingMaskIntoConstraints = false
        col.addSubview(val)

        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: col.topAnchor, constant: 4),
            lbl.centerXAnchor.constraint(equalTo: col.centerXAnchor),
            val.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 3),
            val.centerXAnchor.constraint(equalTo: col.centerXAnchor),
            val.bottomAnchor.constraint(lessThanOrEqualTo: col.bottomAnchor, constant: -2)
        ])
        return col
    }

    private func makeModelBar(name: String, value: Int64, maxValue: Int64, color: NSColor) -> NSView {
        let row = InteractiveRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        row.addSubview(dot)

        let shortName = name.count > 18 ? String(name.prefix(18)) + "…" : name
        let nameLabel = NSTextField(labelWithString: shortName)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = Design.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        let valueLabel = NSTextField(labelWithString: Design.formatTokensK(value))
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = Design.textSecondary
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(valueLabel)

        let bar = ProgressBarView()
        bar.progress = maxValue > 0 ? CGFloat(value) / CGFloat(maxValue) : 0
        bar.fillColor = Design.brandColor  // 进度条用主题主色，不是模型色
        bar.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bar)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            bar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Design.barHeight)
        ])
        return row
    }

    private func addStatRow(sfIcon: String, iconColor: NSColor, title: String, value: String, action: Selector) {
        let row = InteractiveRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let icon = NSImageView(image: NSImage(systemSymbolName: sfIcon, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = iconColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        row.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Design.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = Design.dataHighlightColor  // 主题专属数据色
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(valueLabel)

        let chevron = NSTextField(labelWithString: "›")
        chevron.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        chevron.textColor = Design.textMuted
        chevron.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        row.addGestureRecognizer(NSClickGestureRecognizer(target: AppDelegate.shared, action: action))
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }

    private func addSectionHeader(_ title: String) {
        addSpacer(6)
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Design.textMuted
        label.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(label)
        label.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: 14).isActive = true
        addSpacer(4)
    }

    private func makeIconButton(sfSymbol: String, label: String, action: Selector) -> NSView {
        let container = InteractiveRowView()
        container.hoverColor = Design.activeFill
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 36).isActive = true
        container.wantsLayer = true
        container.layer?.backgroundColor = Design.cardFillDark.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = Design.cardBorderDark.cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: sfSymbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        container.addSubview(icon)

        let title = NSTextField(labelWithString: label)
        title.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        title.textColor = Design.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: -14),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        container.addGestureRecognizer(NSClickGestureRecognizer(target: AppDelegate.shared, action: action))
        return container
    }

    // MARK: - 布局辅助

    private func addSpacer(_ height: CGFloat, to stack: NSStackView? = nil) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        (stack ?? contentStack).addArrangedSubview(spacer)
    }

    private func addSeparator() {
        let sep = NSBox()
        sep.boxType = .separator
        sep.borderColor = Design.separatorColor
        contentStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }

    private func addCenteredLabel(_ text: String, size: CGFloat, color: NSColor) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: .medium)
        label.textColor = color
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        contentStack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }
}
