import Cocoa

// MARK: - 菜单栏动画伴侣（RunCat 式）
//
// 矢量小猫住在菜单栏图标位：今天没用量就睡觉，用量越大跑得越快。
// 三帧（睡 / 迈步A / 迈步B）交替模拟奔跑，帧间隔由预警阈值进度决定。

enum PetPose: String, CaseIterable {
    case sleep, walkA, walkB

    /// 阈值进度（0~1+）→ 帧切换间隔；睡眠态不动画
    static func frameInterval(progress: Double) -> TimeInterval? {
        switch progress {
        case ..<0.0001: return nil          // 睡觉：静态
        case ..<0.35: return 0.55           // 散步
        case ..<0.70: return 0.30           // 跑
        default: return 0.15                // 冲刺
        }
    }

    static func emoji(progress: Double) -> String {
        switch progress {
        case ..<0.0001: return "😴"
        case ..<0.35: return "🙂"
        case ..<0.70: return "😮\u{200D}💨"
        case ..<1.0: return "🥵"
        default: return "🤯"
        }
    }
}

enum MenuPetFrames {
    private static let bodyColor = NSColor(red: 0.94, green: 0.63, blue: 0.31, alpha: 1.0)   // 橘
    private static let darkColor = NSColor(red: 0.42, green: 0.26, blue: 0.10, alpha: 1.0)   // 深棕描边
    private static let innerColor = NSColor(red: 1.00, green: 0.80, blue: 0.75, alpha: 1.0)  // 耳朵内/肚皮

    private static var cache: [PetPose: NSImage] = [:]

    static func image(for pose: PetPose) -> NSImage {
        if let img = cache[pose] { return img }
        let img = NSImage(size: NSSize(width: 16, height: 16))
        image_lock(img)
        switch pose {
        case .sleep: drawSleeping()
        case .walkA: drawRunning(legShift: 0.9)
        case .walkB: drawRunning(legShift: -0.9)
        }
        image_unlock(img)
        img.isTemplate = false
        cache[pose] = img
        return img
    }

    // 画布像素对齐，关闭抗锯齿保持"像素感"
    private static func image_lock(_ image: NSImage) {
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
    }
    private static func image_unlock(_ image: NSImage) {
        image.unlockFocus()
    }

    /// 奔跑姿态：身体 + 抬头 + 立耳 + 上扬尾巴 + 四条腿（两帧错位）
    private static func drawRunning(legShift: CGFloat) {
        let draw = NSBezierPath()
        // 尾巴（从臀部上扬）
        draw.move(to: NSPoint(x: 4, y: 9))
        draw.curve(to: NSPoint(x: 1.2, y: 13),
                   controlPoint1: NSPoint(x: 2.2, y: 9.5),
                   controlPoint2: NSPoint(x: 1.2, y: 11))
        draw.lineWidth = 1.4
        darkColor.setStroke()
        draw.stroke()

        // 身体
        bodyColor.setFill()
        let body = NSBezierPath(ovalIn: NSRect(x: 3.5, y: 7, width: 9.5, height: 4.6))
        body.fill()

        // 头 + 耳朵
        let head = NSBezierPath(ovalIn: NSRect(x: 10.8, y: 6.6, width: 4.6, height: 4.4))
        head.fill()
        darkColor.setFill()
        NSBezierPath(triangleIn: NSRect(x: 11.2, y: 9.6, width: 1.6, height: 1.8)).fill()
        NSBezierPath(triangleIn: NSRect(x: 13.4, y: 9.6, width: 1.6, height: 1.8)).fill()
        innerColor.setFill()
        NSBezierPath(triangleIn: NSRect(x: 11.5, y: 9.8, width: 0.9, height: 1.0)).fill()

        // 眼睛
        darkColor.setFill()
        NSRect(x: 13.6, y: 8.4, width: 0.9, height: 0.9).fill()

        // 四条腿（两帧交错）
        let legY: CGFloat = 6.2
        let legs: [CGFloat] = [5.4 + legShift, 7.0 - legShift, 9.0 + legShift, 10.6 - legShift]
        bodyColor.setFill()
        for lx in legs {
            NSRect(x: lx, y: legY, width: 1.1, height: 2.4).fill()
        }
    }

    /// 睡觉：蜷成团 + 闭眼 + 尾巴圈住
    private static func drawSleeping() {
        bodyColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3.5, y: 5.5, width: 10.5, height: 7.5)).fill()
        // 头埋在前侧
        let head = NSBezierPath(ovalIn: NSRect(x: 9.5, y: 5.8, width: 4.6, height: 4.4))
        head.fill()
        darkColor.setFill()
        NSBezierPath(triangleIn: NSRect(x: 10.0, y: 8.8, width: 1.5, height: 1.7)).fill()
        // 闭眼（一条弧）
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: 12.2, y: 7.6))
        eye.curve(to: NSPoint(x: 13.6, y: 7.6),
                  controlPoint1: NSPoint(x: 12.6, y: 7.1),
                  controlPoint2: NSPoint(x: 13.2, y: 7.1))
        darkColor.setStroke()
        eye.lineWidth = 0.8
        eye.stroke()
        // 尾巴圈住前面
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4, y: 6.5))
        tail.curve(to: NSPoint(x: 11, y: 4.8),
                   controlPoint1: NSPoint(x: 5, y: 3.4),
                   controlPoint2: NSPoint(x: 9, y: 3.4))
        tail.lineWidth = 1.4
        tail.stroke()
    }
}

private extension NSBezierPath {
    convenience init(triangleIn rect: NSRect) {
        self.init()
        move(to: NSPoint(x: rect.minX, y: rect.minY))
        line(to: NSPoint(x: rect.midX, y: rect.maxY))
        line(to: NSPoint(x: rect.maxX, y: rect.minY))
        close()
    }
}

// MARK: - 控制器：状态切换 + 帧动画定时器

final class MenuPetController {
    private var timer: Timer?
    private var button: NSStatusBarButton?
    private var moving = false
    private var frameA = true
    private(set) var enabled = true

    func attach(to button: NSStatusBarButton) {
        self.button = button
        enabled = true
    }

    func detach() {
        enabled = false
        timer?.invalidate()
        timer = nil
        button = nil
    }

    /// 每次标题刷新时调用：按阈值进度切状态（睡觉静止 / 移动翻帧，帧率随进度加快）
    func refresh(progress: Double) {
        guard enabled, let button = button else { return }
        let newInterval = PetPose.frameInterval(progress: progress)
        let nowMoving = newInterval != nil
        if nowMoving != moving {
            moving = nowMoving
            button.image = MenuPetFrames.image(for: nowMoving ? .walkA : .sleep)
        }
        restartTimer(with: newInterval)
    }

    private func restartTimer(with interval: TimeInterval?) {
        timer?.invalidate()
        timer = nil
        guard let interval = interval else { return }   // 睡觉：静态帧，无需动画
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, self.moving, let button = self.button else { return }
            self.frameA.toggle()
            button.image = MenuPetFrames.image(for: self.frameA ? .walkA : .walkB)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}
