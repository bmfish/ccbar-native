import Cocoa

// MARK: - 可交互行视图（hover 高亮 + 点击）

class InteractiveRowView: NSView {
    var isHovered = false
    var hoverColor: NSColor = Design.hoverFill

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1),
                                    xRadius: 6, yRadius: 6)
            hoverColor.setFill()
            path.fill()
        }
    }
}

// MARK: - Sparkline（贝塞尔平滑曲线 + 渐变填充）

class SparklineView: NSView {
    var values: [CGFloat] = []
    var lineColor: NSColor = Design.brandColor
    var fillColor: NSColor = Design.brandColor.withAlphaComponent(0.12)
    var useGradient: Bool = false
    var hueOffset: CGFloat = 0

    var gradientColors: [NSColor] = [
        NSColor(red: 0.30, green: 0.52, blue: 0.95, alpha: 1.0),
        NSColor(red: 0.35, green: 0.78, blue: 0.72, alpha: 1.0),
        NSColor(red: 0.40, green: 0.82, blue: 0.48, alpha: 1.0),
        NSColor(red: 0.95, green: 0.76, blue: 0.30, alpha: 1.0),
        Design.brandColor,
        NSColor(red: 0.90, green: 0.42, blue: 0.58, alpha: 1.0)
    ]

    private func gradientColor(at progress: CGFloat) -> NSColor {
        guard gradientColors.count >= 2 else { return lineColor }
        let p = min(max(progress, 0), 1)
        let scaled = p * CGFloat(gradientColors.count - 1)
        let idx = min(Int(scaled), gradientColors.count - 2)
        let t = scaled - CGFloat(idx)

        guard let c1 = gradientColors[idx].usingColorSpace(.sRGB),
              let c2 = gradientColors[idx + 1].usingColorSpace(.sRGB) else {
            return gradientColors[idx]
        }

        var r = c1.redComponent   + (c2.redComponent   - c1.redComponent)   * t
        var g = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t
        var b = c1.blueComponent  + (c2.blueComponent  - c1.blueComponent)  * t

        if hueOffset != 0 {
            let base = NSColor(red: r, green: g, blue: b, alpha: 1.0).usingColorSpace(.sRGB) ?? NSColor.white
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            let rotated = NSColor(hue: (h + hueOffset).truncatingRemainder(dividingBy: 1.0),
                                  saturation: s, brightness: br, alpha: 1.0).usingColorSpace(.sRGB) ?? base
            r = rotated.redComponent
            g = rotated.greenComponent
            b = rotated.blueComponent
        }
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // Catmull-Rom 样条插值（比直线平滑）
    private func catmullRomPoints(from pts: [NSPoint], segments: Int = 6) -> [NSPoint] {
        guard pts.count >= 2 else { return pts }
        var result: [NSPoint] = []
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2

            for s in 0..<segments {
                let t = CGFloat(s) / CGFloat(segments)
                let t2 = t * t
                let t3 = t2 * t

                let x = 0.5 * ((2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                    (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                    (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                result.append(NSPoint(x: x, y: y))
            }
        }
        result.append(pts.last!)
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard values.count > 1 else { return }

        let maxVal = values.max() ?? 1
        let minVal = values.min() ?? 0
        let range = maxVal - minVal
        let stepX = bounds.width / CGFloat(values.count - 1)
        let padding: CGFloat = 5
        let availableHeight = bounds.height - padding * 2

        // 计算原始数据点
        var rawPoints: [NSPoint] = []
        for (i, val) in values.enumerated() {
            let x = CGFloat(i) * stepX
            let normalized = range > 0 ? (val - minVal) / range : 0.5
            let y = padding + normalized * availableHeight
            rawPoints.append(NSPoint(x: x, y: y))
        }

        // 贝塞尔平滑插值
        let smoothPoints = catmullRomPoints(from: rawPoints, segments: 5)
        let count = smoothPoints.count

        // 渐变填充区域
        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: smoothPoints[0].x, y: padding))
        for point in smoothPoints {
            fillPath.line(to: point)
        }
        fillPath.line(to: NSPoint(x: smoothPoints.last!.x, y: padding))
        fillPath.close()

        let topColor: NSColor = useGradient
            ? gradientColor(at: 0.5).withAlphaComponent(0.18)
            : fillColor
        let bottomColor = topColor.withAlphaComponent(0.0)

        if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
            gradient.draw(in: fillPath, angle: 90)
        } else {
            topColor.setFill()
            fillPath.fill()
        }

        // 分段绘制平滑折线
        for i in 0..<(count - 1) {
            let segment = NSBezierPath()
            segment.lineWidth = Theme.current.sparklineLineWidth
            segment.lineCapStyle = .round
            segment.lineJoinStyle = .round
            segment.move(to: smoothPoints[i])
            segment.line(to: smoothPoints[i + 1])

            let color: NSColor
            if useGradient {
                let progress = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
                color = gradientColor(at: progress)
            } else {
                color = lineColor
            }
            color.setStroke()
            segment.stroke()
        }

        // 终点圆点
        if let lastPoint = smoothPoints.last {
            let dotRadius: CGFloat = 3.0
            let dotRect = NSRect(x: lastPoint.x - dotRadius, y: lastPoint.y - dotRadius,
                               width: dotRadius * 2, height: dotRadius * 2)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            let endColor = useGradient ? gradientColor(at: 1.0) : lineColor
            endColor.setFill()
            dotPath.fill()

            let ringPath = NSBezierPath(ovalIn: dotRect.insetBy(dx: -2, dy: -2))
            ringPath.lineWidth = 1.0
            endColor.withAlphaComponent(0.30).setStroke()
            ringPath.stroke()
        }
    }
}

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

// MARK: - 渐变头部条

class GradientHeaderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let gradient = NSGradient(starting: Design.brandColor.withAlphaComponent(0.7),
                                        ending: Design.brandColor.withAlphaComponent(0.0)) else { return }
        gradient.draw(in: bounds, angle: 0)
    }
}

// MARK: - 柱状图（支持渐变色）

class BarChartView: NSView {
    var values: [CGFloat] = []
    var labels: [String] = []
    var barColor: NSColor = Design.brandColor

    // 渐变模式（和折线图一致的配色）
    var useGradient: Bool = false
    var hueOffset: CGFloat = 0

    var gradientColors: [NSColor] = [
        NSColor(red: 0.30, green: 0.52, blue: 0.95, alpha: 1.0),
        NSColor(red: 0.35, green: 0.78, blue: 0.72, alpha: 1.0),
        NSColor(red: 0.40, green: 0.82, blue: 0.48, alpha: 1.0),
        NSColor(red: 0.95, green: 0.76, blue: 0.30, alpha: 1.0),
        Design.brandColor,
        NSColor(red: 0.90, green: 0.42, blue: 0.58, alpha: 1.0)
    ]

    private func gradientColor(at progress: CGFloat) -> NSColor {
        guard gradientColors.count >= 2 else { return barColor }
        let p = min(max(progress, 0), 1)
        let scaled = p * CGFloat(gradientColors.count - 1)
        let idx = min(Int(scaled), gradientColors.count - 2)
        let t = scaled - CGFloat(idx)
        guard let c1 = gradientColors[idx].usingColorSpace(.sRGB),
              let c2 = gradientColors[idx + 1].usingColorSpace(.sRGB) else { return gradientColors[idx] }
        var r = c1.redComponent + (c2.redComponent - c1.redComponent) * t
        var g = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t
        var b = c1.blueComponent + (c2.blueComponent - c1.blueComponent) * t
        if hueOffset != 0 {
            let base = NSColor(red: r, green: g, blue: b, alpha: 1.0).usingColorSpace(.sRGB) ?? NSColor.white
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            let rotated = NSColor(hue: (h + hueOffset).truncatingRemainder(dividingBy: 1.0),
                                  saturation: s, brightness: br, alpha: 1.0).usingColorSpace(.sRGB) ?? base
            r = rotated.redComponent; g = rotated.greenComponent; b = rotated.blueComponent
        }
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !values.isEmpty else { return }
        let maxVal = values.max() ?? 1
        guard maxVal > 0 else { return }

        let count = CGFloat(values.count)
        let spacing: CGFloat = max(1, min(2, (bounds.width - count * 3) / count))
        let barWidth = max((bounds.width - spacing * (count - 1)) / count, 2)
        let bottomPad: CGFloat = labels.isEmpty ? 4 : 14
        let topPad: CGFloat = 3
        let availableH = bounds.height - bottomPad - topPad

        for (i, val) in values.enumerated() {
            let h = (val / maxVal) * availableH
            let x = CGFloat(i) * (barWidth + spacing)
            let y = bottomPad

            let barRect = NSRect(x: x, y: y, width: barWidth, height: max(h, 1))
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)

            // 颜色
            let color: NSColor
            if useGradient {
                let progress = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
                color = gradientColor(at: progress)
            } else {
                color = barColor
            }

            // 渐变填充（底部暗、顶部亮）
            let top = color.withAlphaComponent(0.90)
            let bottom = color.withAlphaComponent(0.45)
            if let grad = NSGradient(starting: bottom, ending: top) {
                grad.draw(in: barPath, angle: 90)
            } else {
                color.setFill()
                barPath.fill()
            }

            // 标签
            if i < labels.count && (values.count <= 15 || i % 2 == 0) {
                let lbl = labels[i] as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                    .foregroundColor: Design.textMuted
                ]
                let sz = lbl.size(withAttributes: attrs)
                lbl.draw(at: NSPoint(x: x + (barWidth - sz.width) / 2, y: 1), withAttributes: attrs)
            }
        }
    }
}
