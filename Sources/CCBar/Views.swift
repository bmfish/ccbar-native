import Cocoa

// MARK: - 进度条（圆角 + 微妙渐变）

class ProgressBarView: NSView {
    var progress: CGFloat = 0
    var trackColor: NSColor = NSColor.white.withAlphaComponent(0.08)
    var fillColor: NSColor = Design.brandColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 轨道
        let trackRect = NSRect(x: 0, y: (bounds.height - Design.barHeight) / 2,
                              width: bounds.width, height: Design.barHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: Design.barCornerRadius,
                                    yRadius: Design.barCornerRadius)
        trackColor.setFill()
        trackPath.fill()

        // 填充（带微弱高光渐变）
        let fillWidth = bounds.width * min(max(progress, 0), 1)
        guard fillWidth > 0 else { return }

        let fillRect = NSRect(x: 0, y: (bounds.height - Design.barHeight) / 2,
                             width: fillWidth, height: Design.barHeight)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: Design.barCornerRadius,
                                   yRadius: Design.barCornerRadius)

        let topColor = fillColor.withAlphaComponent(0.95)
        let bottomColor = fillColor.withAlphaComponent(0.65)
        if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
            gradient.draw(in: fillPath, angle: 90)
        } else {
            fillColor.setFill()
            fillPath.fill()
        }
    }
}

// MARK: - 环形图 + 图例

class DonutChartView: NSView {
    var items: [(value: CGFloat, color: NSColor)] = []
    var lineWidth: CGFloat = 16

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !items.isEmpty else { return }
        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0 else { return }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - lineWidth / 2
        var startAngle: CGFloat = 90

        for item in items {
            let sweep = item.value / total * 360
            let endAngle = startAngle - sweep
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius,
                          startAngle: startAngle, endAngle: endAngle, clockwise: true)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            item.color.setStroke()
            path.stroke()
            startAngle = endAngle
        }
    }
}

class DonutChartWithLegendView: NSView {
    struct Item {
        let value: CGFloat
        let color: NSColor
        let label: String
        let percentage: String
    }

    var items: [Item] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !items.isEmpty else { return }

        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0 else { return }

        let donutSize: CGFloat = min(bounds.height * 0.85, 100)
        let center = NSPoint(x: donutSize / 2 + 4, y: bounds.midY)
        let radius = donutSize / 2 - 8
        let lineWidth: CGFloat = 11
        var startAngle: CGFloat = 90

        for item in items {
            let sweep = item.value / total * 360
            let endAngle = startAngle - sweep
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius,
                          startAngle: startAngle, endAngle: endAngle, clockwise: true)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            item.color.setStroke()
            path.stroke()
            startAngle = endAngle
        }

        // 图例
        let legendX: CGFloat = donutSize + 16
        var legendY: CGFloat = bounds.height - 16

        for item in items {
            let dotRect = NSRect(x: legendX, y: legendY - 5, width: 8, height: 8)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            item.color.setFill()
            dotPath.fill()

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: Design.textPrimary
            ]
            (item.label as NSString).draw(at: NSPoint(x: legendX + 14, y: legendY - 6), withAttributes: labelAttrs)

            let pctAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Design.textSecondary
            ]
            let pctStr = item.percentage as NSString
            let pctSize = pctStr.size(withAttributes: pctAttrs)
            pctStr.draw(at: NSPoint(x: bounds.width - pctSize.width - 4, y: legendY - 6), withAttributes: pctAttrs)

            legendY -= 18
        }
    }
}

// MARK: - CRT 扫描线覆盖层（仅 CRT 主题显示）

class ScanlineOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 不拦截点击

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.10).setFill()
        var y: CGFloat = 0
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            y += 3
        }
    }
}

// MARK: - 渐变头部条

class GradientHeaderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let gradient = NSGradient(starting: Design.brandColor.withAlphaComponent(0.7),
                                        ending: Design.brandColor.withAlphaComponent(0.0)) else { return }
        gradient.draw(in: bounds, angle: 0)
    }
}
