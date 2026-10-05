import Cocoa

// MARK: - 主题（内置 6 套 + 自定义 JSON 主题包）

/// 主题定义：颜色一律 hex 字符串存储（JSON 包直接可读可改），NSColor 按需解析。
/// 内置主题的色值与旧枚举逐字段等价（系统色 systemBlue 等已折算成具体 hex），
/// id 沿用旧枚举 rawValue，老用户的 UserDefaults 偏好无需迁移。
struct Theme: Equatable, Hashable, Identifiable, Codable {
    var id: String
    var name: String
    var accentHex: String
    var dataHex: String
    var bigNumberHex: String        // 空 = 跟随 accent
    var trendHexes: [String]        // [昨日, 周, 月]；总量色用 accent
    var modelHexes: [String]        // 6 色
    var glowRadius: CGFloat
    var glowAlpha: CGFloat
    var cardFillAlpha: CGFloat
    var cardBorderAlpha: CGFloat
    var separatorAlpha: CGFloat
    var bigNumberWeightName: String // "bold" / "heavy"
    var scanlines: Bool             // CRT 扫描线特效

    // ---- NSColor 视图 ----
    var accent: NSColor { NSColor(hex: accentHex) }
    var dataColor: NSColor { NSColor(hex: dataHex) }
    var bigNumberColor: NSColor { bigNumberHex.isEmpty ? accent : NSColor(hex: bigNumberHex) }
    var bigNumberWeight: NSFont.Weight { bigNumberWeightName == "heavy" ? .heavy : .bold }
    var bigNumberFontSize: CGFloat { 30 }
    var trendIconColors: (yesterday: NSColor, week: NSColor, month: NSColor, total: NSColor) {
        (NSColor(hex: trendHexes[0]), NSColor(hex: trendHexes[1]),
         NSColor(hex: trendHexes[2]), accent)
    }
    var modelColors: [NSColor] { modelHexes.map { NSColor(hex: $0) } }

    // ---- JSON 主题包 ----

    private enum Keys: String, CodingKey {
        case format, version, name
        case accent, data, bigNumber, trend, models
        case glowRadius, glowAlpha, cardFillAlpha, cardBorderAlpha, separatorAlpha
        case bigNumberWeight, scanlines
    }

    init(id: String, name: String, accentHex: String, dataHex: String, bigNumberHex: String,
         trendHexes: [String], modelHexes: [String], glowRadius: CGFloat, glowAlpha: CGFloat,
         cardFillAlpha: CGFloat, cardBorderAlpha: CGFloat, separatorAlpha: CGFloat,
         bigNumberWeightName: String, scanlines: Bool) {
        self.id = id
        self.name = name
        self.accentHex = accentHex
        self.dataHex = dataHex
        self.bigNumberHex = bigNumberHex
        self.trendHexes = trendHexes
        self.modelHexes = modelHexes
        self.glowRadius = glowRadius
        self.glowAlpha = glowAlpha
        self.cardFillAlpha = cardFillAlpha
        self.cardBorderAlpha = cardBorderAlpha
        self.separatorAlpha = separatorAlpha
        self.bigNumberWeightName = bigNumberWeightName
        self.scanlines = scanlines
    }

    /// 手改主题包也尽量能读：缺字段回落默认主题，format 不对才拒收
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let f = try c.decodeIfPresent(String.self, forKey: .format), f != "ccbar-theme" {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "不是 ccBar 主题包")
        }
        let d = Theme.classic
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        accentHex = try c.decodeIfPresent(String.self, forKey: .accent) ?? d.accentHex
        dataHex = try c.decodeIfPresent(String.self, forKey: .data) ?? d.dataHex
        bigNumberHex = try c.decodeIfPresent(String.self, forKey: .bigNumber) ?? ""
        trendHexes = try c.decodeIfPresent([String].self, forKey: .trend) ?? d.trendHexes
        modelHexes = try c.decodeIfPresent([String].self, forKey: .models) ?? d.modelHexes
        glowRadius = try c.decodeIfPresent(CGFloat.self, forKey: .glowRadius) ?? d.glowRadius
        glowAlpha = try c.decodeIfPresent(CGFloat.self, forKey: .glowAlpha) ?? d.glowAlpha
        cardFillAlpha = try c.decodeIfPresent(CGFloat.self, forKey: .cardFillAlpha) ?? d.cardFillAlpha
        cardBorderAlpha = try c.decodeIfPresent(CGFloat.self, forKey: .cardBorderAlpha) ?? d.cardBorderAlpha
        separatorAlpha = try c.decodeIfPresent(CGFloat.self, forKey: .separatorAlpha) ?? d.separatorAlpha
        bigNumberWeightName = try c.decodeIfPresent(String.self, forKey: .bigNumberWeight) ?? d.bigNumberWeightName
        scanlines = try c.decodeIfPresent(Bool.self, forKey: .scanlines) ?? d.scanlines
        id = ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode("ccbar-theme", forKey: .format)
        try c.encode(1, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(accentHex, forKey: .accent)
        try c.encode(dataHex, forKey: .data)
        try c.encode(bigNumberHex, forKey: .bigNumber)
        try c.encode(trendHexes, forKey: .trend)
        try c.encode(modelHexes, forKey: .models)
        try c.encode(glowRadius, forKey: .glowRadius)
        try c.encode(glowAlpha, forKey: .glowAlpha)
        try c.encode(cardFillAlpha, forKey: .cardFillAlpha)
        try c.encode(cardBorderAlpha, forKey: .cardBorderAlpha)
        try c.encode(separatorAlpha, forKey: .separatorAlpha)
        try c.encode(bigNumberWeightName, forKey: .bigNumberWeight)
        try c.encode(scanlines, forKey: .scanlines)
    }

    /// 解析主题包 JSON；无效返回 nil
    static func fromJSON(_ data: Data) -> Theme? {
        guard var t = try? JSONDecoder().decode(Theme.self, from: data) else { return nil }
        t.id = "custom-\(UUID().uuidString)"
        if t.trendHexes.count != 3 { t.trendHexes = classic.trendHexes }
        if t.modelHexes.isEmpty { t.modelHexes = classic.modelHexes }
        return t
    }

    // ---- 内置主题 ----

    static let classic = Theme(
        id: "默认主题", name: "默认主题",
        accentHex: "#E86E45", dataHex: "#F2B373", bigNumberHex: "",
        trendHexes: ["#007AFF", "#AF52DE", "#32ADE2"],
        modelHexes: ["#E86E45", "#598CF2", "#40C78C", "#F29E4D", "#9980FA", "#F266AD"],
        glowRadius: 14, glowAlpha: 0.30, cardFillAlpha: 0.06, cardBorderAlpha: 0.10,
        separatorAlpha: 0.10, bigNumberWeightName: "bold", scanlines: false)

    static let kawaii01 = Theme(
        id: "卡哇伊 01", name: "卡哇伊 01",
        accentHex: "#F25994", dataHex: "#FFFFFF", bigNumberHex: "#FF6BA6",
        trendHexes: ["#66CCA6", "#8099F2", "#BF80F2"],
        modelHexes: ["#FF73A6", "#66A6F2", "#B380F2", "#66D199", "#FFA64D", "#F2CC66"],
        glowRadius: 20, glowAlpha: 0.45, cardFillAlpha: 0.08, cardBorderAlpha: 0.15,
        separatorAlpha: 0.15, bigNumberWeightName: "heavy", scanlines: false)

    static let ocean = Theme(
        id: "海蓝", name: "海蓝",
        accentHex: "#2E8CF2", dataHex: "#59BFFF", bigNumberHex: "#409EFF",
        trendHexes: ["#40B3E6", "#6680E6", "#33CCBF"],
        modelHexes: ["#2E8CF2", "#1ABFD9", "#80A6F2", "#73CC8C", "#D98C40", "#A666E6"],
        glowRadius: 14, glowAlpha: 0.30, cardFillAlpha: 0.06, cardBorderAlpha: 0.10,
        separatorAlpha: 0.10, bigNumberWeightName: "bold", scanlines: false)

    static let forest = Theme(
        id: "翠绿", name: "翠绿",
        accentHex: "#29B86B", dataHex: "#66E08C", bigNumberHex: "#38CC7A",
        trendHexes: ["#33A673", "#73BF4D", "#1A99B3"],
        modelHexes: ["#29B86B", "#338C59", "#80CC4D", "#1AA6BF", "#D9A633", "#B36633"],
        glowRadius: 14, glowAlpha: 0.30, cardFillAlpha: 0.06, cardBorderAlpha: 0.10,
        separatorAlpha: 0.10, bigNumberWeightName: "bold", scanlines: false)

    static let purple = Theme(
        id: "星空紫", name: "星空紫",
        accentHex: "#8C52F2", dataHex: "#B88CFF", bigNumberHex: "#9E66FF",
        trendHexes: ["#9973E6", "#CC59D9", "#598CE6"],
        modelHexes: ["#8C52F2", "#CC59F2", "#4D80F2", "#F26699", "#73CCA6", "#F2A64D"],
        glowRadius: 14, glowAlpha: 0.30, cardFillAlpha: 0.06, cardBorderAlpha: 0.10,
        separatorAlpha: 0.10, bigNumberWeightName: "bold", scanlines: false)

    static let crt = Theme(
        id: "CRT 终端", name: "CRT 终端",
        accentHex: "#4DF28C", dataHex: "#99FFBF", bigNumberHex: "",
        trendHexes: ["#66E68C", "#D9E666", "#4DD9B3"],
        modelHexes: ["#4DF28C", "#33BF66", "#99FFBF", "#E6E659", "#26994D", "#73E6D9"],
        glowRadius: 12, glowAlpha: 0.40, cardFillAlpha: 0.05, cardBorderAlpha: 0.20,
        separatorAlpha: 0.10, bigNumberWeightName: "bold", scanlines: true)

    static let builtins = [classic, kawaii01, ocean, forest, purple, crt]

    // ---- 自定义主题持久化 ----

    static var customThemes: [Theme] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "customThemes") else { return [] }
            return (try? JSONDecoder().decode([Theme].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "customThemes")
            }
        }
    }

    static func addCustom(_ theme: Theme) {
        var list = customThemes
        list.removeAll { $0.id == theme.id }
        list.append(theme)
        customThemes = list
    }

    static var allThemes: [Theme] { builtins + customThemes }

    static func find(id: String) -> Theme? {
        builtins.first { $0.id == id } ?? customThemes.first { $0.id == id }
    }

    static var current: Theme {
        get {
            let saved = UserDefaults.standard.string(forKey: "theme") ?? ""
            return find(id: saved) ?? classic
        }
        set { UserDefaults.standard.set(newValue.id, forKey: "theme") }
    }

    var displayName: String { name }
}

extension NSColor {
    /// "#RRGGBB" / "#RGB" → NSColor（非法输入回落白色，不让主题包打崩界面）
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 6, let v = UInt32(s, radix: 16) {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
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
        // 拆开算：整条混合表达式会让旧版编译器类型检查超时
        let year = c.year ?? 0
        let month = c.month ?? 0
        let day = c.day ?? 0
        let hour = c.hour ?? 0
        let combined = year * 1_000_000 + month * 10_000 + day * 100 + hour
        return UInt64(combined)
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
        L10n.formatTokens(n)
    }

    static func formatTokensK(_ n: Int64) -> String {
        L10n.formatTokens(n)
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
