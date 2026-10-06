import Cocoa

// MARK: - 环形图 + 图例（模型分布详情窗口用，经 NSViewRepresentable 桥进 SwiftUI）

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
