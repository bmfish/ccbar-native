import Cocoa

// MARK: - 主题（每套有完整的视觉风格）

enum Theme: String, CaseIterable {
    case `default` = "默认主题"
    case kawaii01  = "卡哇伊 01"
    case ocean     = "海蓝"
    case forest    = "翠绿"
    case purple    = "星空紫"

    // 主色（大数字、渐变条、品牌标识）
    var accent: NSColor {
        switch self {
        case .default: return NSColor(red: 0.91, green: 0.43, blue: 0.27, alpha: 1.0) // 暖橙
        case .kawaii01: return NSColor(red: 0.95, green: 0.35, blue: 0.58, alpha: 1.0) // 粉红
        case .ocean: return NSColor(red: 0.18, green: 0.55, blue: 0.95, alpha: 1.0) // 海蓝
        case .forest: return NSColor(red: 0.16, green: 0.72, blue: 0.42, alpha: 1.0) // 翠绿
        case .purple: return NSColor(red: 0.55, green: 0.32, blue: 0.95, alpha: 1.0) // 星空紫
        }
    }

    // 数据高亮色（趋势行数值）
    var dataColor: NSColor {
        switch self {
        case .default: return NSColor(red: 0.95, green: 0.70, blue: 0.45, alpha: 1.0)
        case .kawaii01: return NSColor.white
        case .ocean: return NSColor(red: 0.35, green: 0.75, blue: 1.00, alpha: 1.0) // 天蓝
        case .forest: return NSColor(red: 0.40, green: 0.88, blue: 0.55, alpha: 1.0) // 嫩绿
        case .purple: return NSColor(red: 0.72, green: 0.55, blue: 1.00, alpha: 1.0) // 淡紫
        }
    }

    // 大数字色
    var bigNumberColor: NSColor {
        switch self {
        case .default: return accent
        case .kawaii01: return NSColor(red: 1.00, green: 0.42, blue: 0.65, alpha: 1.0)
        case .ocean: return NSColor(red: 0.25, green: 0.62, blue: 1.00, alpha: 1.0)
        case .forest: return NSColor(red: 0.22, green: 0.80, blue: 0.48, alpha: 1.0)
        case .purple: return NSColor(red: 0.62, green: 0.40, blue: 1.00, alpha: 1.0)
        }
    }

    // 大数字字号
    var bigNumberFontSize: CGFloat { 30 }

    // 大数字字重
    var bigNumberWeight: NSFont.Weight {
        switch self {
        case .kawaii01: return .heavy
        default: return .bold
        }
    }

    // 发光效果强度
    var glowRadius: CGFloat {
        switch self {
        case .kawaii01: return 20
        default: return 14
        }
    }

    var glowAlpha: CGFloat {
        switch self {
        case .kawaii01: return 0.45
        default: return 0.30
        }
    }

    // 卡片透明度
    var cardFillAlpha: CGFloat {
        switch self {
        case .kawaii01: return 0.08
        default: return 0.06
        }
    }

    var cardBorderAlpha: CGFloat {
        switch self {
        case .kawaii01: return 0.15
        default: return 0.10
        }
    }

    // 趋势行图标色
    var trendIconColors: (yesterday: NSColor, week: NSColor, month: NSColor, total: NSColor) {
        switch self {
        case .default:
            return (.systemBlue, .systemPurple, .systemTeal, accent)
        case .kawaii01:
            return (NSColor(red: 0.40, green: 0.80, blue: 0.65, alpha: 1.0),
                    NSColor(red: 0.50, green: 0.60, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.75, green: 0.50, blue: 0.95, alpha: 1.0),
                    NSColor(red: 1.00, green: 0.55, blue: 0.35, alpha: 1.0))
        case .ocean:
            return (NSColor(red: 0.25, green: 0.70, blue: 0.90, alpha: 1.0),
                    NSColor(red: 0.40, green: 0.50, blue: 0.90, alpha: 1.0),
                    NSColor(red: 0.20, green: 0.80, blue: 0.75, alpha: 1.0),
                    accent)
        case .forest:
            return (NSColor(red: 0.20, green: 0.65, blue: 0.45, alpha: 1.0),
                    NSColor(red: 0.45, green: 0.75, blue: 0.30, alpha: 1.0),
                    NSColor(red: 0.10, green: 0.60, blue: 0.70, alpha: 1.0),
                    accent)
        case .purple:
            return (NSColor(red: 0.60, green: 0.45, blue: 0.90, alpha: 1.0),
                    NSColor(red: 0.80, green: 0.35, blue: 0.85, alpha: 1.0),
                    NSColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1.0),
                    accent)
        }
    }

    // 模型配色
    var modelColors: [NSColor] {
        switch self {
        case .default:
            return [accent,
                    NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.25, green: 0.78, blue: 0.55, alpha: 1.0),
                    NSColor(red: 0.95, green: 0.62, blue: 0.30, alpha: 1.0),
                    NSColor(red: 0.60, green: 0.50, blue: 0.98, alpha: 1.0),
                    NSColor(red: 0.95, green: 0.40, blue: 0.68, alpha: 1.0)]
        case .kawaii01:
            return [NSColor(red: 1.00, green: 0.45, blue: 0.65, alpha: 1.0),
                    NSColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.70, green: 0.50, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.40, green: 0.82, blue: 0.60, alpha: 1.0),
                    NSColor(red: 1.00, green: 0.65, blue: 0.30, alpha: 1.0),
                    NSColor(red: 0.95, green: 0.80, blue: 0.40, alpha: 1.0)]
        case .ocean:
            return [accent,
                    NSColor(red: 0.10, green: 0.75, blue: 0.85, alpha: 1.0),
                    NSColor(red: 0.50, green: 0.65, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.45, green: 0.80, blue: 0.55, alpha: 1.0),
                    NSColor(red: 0.85, green: 0.55, blue: 0.25, alpha: 1.0),
                    NSColor(red: 0.65, green: 0.40, blue: 0.90, alpha: 1.0)]
        case .forest:
            return [accent,
                    NSColor(red: 0.20, green: 0.55, blue: 0.35, alpha: 1.0),
                    NSColor(red: 0.50, green: 0.80, blue: 0.30, alpha: 1.0),
                    NSColor(red: 0.10, green: 0.65, blue: 0.75, alpha: 1.0),
                    NSColor(red: 0.85, green: 0.65, blue: 0.20, alpha: 1.0),
                    NSColor(red: 0.70, green: 0.40, blue: 0.20, alpha: 1.0)]
        case .purple:
            return [accent,
                    NSColor(red: 0.80, green: 0.35, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.30, green: 0.50, blue: 0.95, alpha: 1.0),
                    NSColor(red: 0.95, green: 0.40, blue: 0.60, alpha: 1.0),
                    NSColor(red: 0.45, green: 0.80, blue: 0.65, alpha: 1.0),
                    NSColor(red: 0.95, green: 0.65, blue: 0.30, alpha: 1.0)]
        }
    }

    // 进度条风格
    var progressLineWidth: CGFloat {
        switch self {
        case .kawaii01: return 2.2
        default: return 1.8
        }
    }

    // sparkline 线宽
    var sparklineLineWidth: CGFloat {
        switch self {
        case .kawaii01: return 2.2
        default: return 1.8
        }
    }

    // 分隔线透明度
    var separatorAlpha: CGFloat {
        switch self {
        case .kawaii01: return 0.15
        default: return 0.10
        }
    }

    static var current: Theme {
        get { Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .default }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
    }

    var displayName: String { rawValue }
}

// MARK: - Design System

enum Design {
    // 品牌色（跟随主题）
    static var brandColor: NSColor { Theme.current.accent }
    static var dataHighlightColor: NSColor { Theme.current.dataColor }
    static var bigNumberColor: NSColor { Theme.current.bigNumberColor }

    // 卡片样式（跟随主题）
    static var cardFillDark: NSColor { NSColor.white.withAlphaComponent(Theme.current.cardFillAlpha) }
    static var cardBorderDark: NSColor { NSColor.white.withAlphaComponent(Theme.current.cardBorderAlpha) }
    static var separatorColor: NSColor { NSColor.white.withAlphaComponent(Theme.current.separatorAlpha) }

    // 固定值
    static let cardCornerRadius: CGFloat = 10
    static let barCornerRadius: CGFloat = 3.5
    static let barHeight: CGFloat = 6

    // 深色背景（不随主题变）
    static let backgroundDark = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    static let textPrimary = NSColor.white
    static let textSecondary = NSColor.white.withAlphaComponent(0.60)
    static let textMuted = NSColor.white.withAlphaComponent(0.38)

    /// 毛玻璃材质上垫一层深色底：hudWindow 材质是半透明的，
    /// 弹窗悬浮在亮色页面上时白字会看不清，这层保证对比度，同时留一点通透感
    static func addDarkTint(overBlurIn parent: NSView) {
        let tint = NSView(frame: parent.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = backgroundDark.withAlphaComponent(0.8).cgColor
        parent.addSubview(tint)
    }
    static let hoverFill = NSColor.white.withAlphaComponent(0.07)
    static let activeFill = NSColor.white.withAlphaComponent(0.10)

    // 状态色
    static let successColor = NSColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 1.0)
    static let warningColor = NSColor(red: 0.95, green: 0.70, blue: 0.30, alpha: 1.0)
    static let errorColor = NSColor(red: 0.95, green: 0.30, blue: 0.35, alpha: 1.0)

    // MARK: - 用量色阶（绿 → 黄 → 橙 → 红）

    private static let usageStops: [(pos: CGFloat, color: NSColor)] = [
        (0.00, NSColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0)),
        (0.35, NSColor(red: 0.60, green: 0.85, blue: 0.40, alpha: 1.0)),
        (0.60, NSColor(red: 0.95, green: 0.78, blue: 0.30, alpha: 1.0)),
        (0.82, NSColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 1.0)),
        (1.00, NSColor(red: 0.90, green: 0.25, blue: 0.28, alpha: 1.0)),
    ]

    static func usageColor(progress: CGFloat) -> NSColor {
        let p = min(max(progress, 0), 1)
        for i in 0..<(usageStops.count - 1) {
            let a = usageStops[i]; let b = usageStops[i + 1]
            if p <= b.pos {
                let t = (b.pos - a.pos) > 0 ? (p - a.pos) / (b.pos - a.pos) : 0
                guard let c1 = a.color.usingColorSpace(.sRGB),
                      let c2 = b.color.usingColorSpace(.sRGB) else { return a.color }
                return NSColor(
                    red: c1.redComponent + (c2.redComponent - c1.redComponent) * t,
                    green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t,
                    blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * t,
                    alpha: 1.0)
            }
        }
        return usageStops.last!.color
    }

    static func usageColor(total: Int64, thresholdWan: Int) -> NSColor {
        let threshold = Double(thresholdWan) * 10_000
        guard threshold > 0 else { return usageStops.first!.color }
        return usageColor(progress: CGFloat(min(Double(total) / threshold / 1.2, 1.0)))
    }

    // MARK: - 模型配色

    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    private static func hourSeed() -> UInt64 {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: Date())
        return UInt64((c.year ?? 0) * 1_000_000 + (c.month ?? 0) * 10_000 + (c.day ?? 0) * 100 + (c.hour ?? 0))
    }

    static func modelColors(count: Int = 6) -> [NSColor] {
        var colors = Theme.current.modelColors
        var rng = SeededRandom(seed: hourSeed())
        if colors.count > 1 {
            for i in stride(from: colors.count - 1, through: 1, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1))
                colors.swapAt(i, j)
            }
        }
        return (0..<count).map { colors[$0 % colors.count] }
    }

    // MARK: - 格式化

    static func formatTokens(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }
        else if n >= 10_000 { return "\(n / 10_000)万" }
        else { return "\(n)" }
    }

    static func formatTokensK(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }
        else if n >= 10_000 { return "\(n / 10_000)万" }
        else { return "\(n)" }
    }
}

// MARK: - 六段渐变调色板（Sparkline / BarChart 共用）

enum GradientPalette {
    /// 每次取值都重新读主题品牌色，保证切主题后立即生效
    static var stops: [NSColor] {
        return [
            NSColor(red: 0.30, green: 0.52, blue: 0.95, alpha: 1.0),
            NSColor(red: 0.35, green: 0.78, blue: 0.72, alpha: 1.0),
            NSColor(red: 0.40, green: 0.82, blue: 0.48, alpha: 1.0),
            NSColor(red: 0.95, green: 0.76, blue: 0.30, alpha: 1.0),
            Design.brandColor,
            NSColor(red: 0.90, green: 0.42, blue: 0.58, alpha: 1.0)
        ]
    }

    static func color(at progress: CGFloat, hueOffset: CGFloat, fallback: NSColor) -> NSColor {
        let stops = self.stops
        guard stops.count >= 2 else { return fallback }
        let p = min(max(progress, 0), 1)
        let scaled = p * CGFloat(stops.count - 1)
        let idx = min(Int(scaled), stops.count - 2)
        let t = scaled - CGFloat(idx)

        guard let c1 = stops[idx].usingColorSpace(.sRGB),
              let c2 = stops[idx + 1].usingColorSpace(.sRGB) else {
            return stops[idx]
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
}
