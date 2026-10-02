import Cocoa

// MARK: - 菜单栏动画伴侣（RunCat 式）
//
// 像素小猫住在菜单栏图标位：今天没用量就睡觉，用量越大跑得越快。
// 三帧（睡 / 迈步A / 迈步B）交替模拟奔跑，帧间隔由预警阈值进度决定。
// 绘制全部为整数像素块（关闭抗锯齿），真·像素风。

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
    private static let orange = NSColor(red: 0.95, green: 0.62, blue: 0.28, alpha: 1.0)
    private static let dark   = NSColor(red: 0.35, green: 0.21, blue: 0.08, alpha: 1.0)
    private static let white  = NSColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1.0)
    private static let pink   = NSColor(red: 0.98, green: 0.62, blue: 0.62, alpha: 1.0)

    private static var cache: [PetPose: NSImage] = [:]

    static func image(for pose: PetPose) -> NSImage {
        if let img = cache[pose] { return img }
        let img = NSImage(size: NSSize(width: 16, height: 16))
        img.lockFocus()
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        switch pose {
        case .sleep: drawSleeping()
        case .walkA: drawRunning(legShift: 1)
        case .walkB: drawRunning(legShift: -1)
        }
        img.unlockFocus()
        img.isTemplate = false
        cache[pose] = img
        return img
    }

    /// 画一个整数像素块（坐标为 AppKit y-up）
    private static func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: NSColor) {
        color.setFill()
        NSRect(x: x, y: y, width: w, height: h).fill()
    }

    /// 奔跑姿态（y-up 像素坐标）：阶梯尾巴 + 方身方头 + 立耳 + 四条腿两帧交错
    private static func drawRunning(legShift: Int) {
        // 尾巴（臀部向左上扬起的阶梯）
        px(2, 9, 1, 1, dark)
        px(1, 10, 1, 1, dark)
        px(1, 11, 1, 1, dark)
        px(1, 12, 1, 1, dark)

        // 身体 x4..x11, y8..y11
        px(4, 8, 8, 4, orange)
        // 肚皮白
        px(9, 8, 2, 2, white)
        // 背部两条深色虎纹
        px(6, 10, 1, 2, dark)
        px(8, 10, 1, 2, dark)

        // 头 x10..x14, y10..y13（与身体前端重叠衔接）
        px(10, 10, 5, 4, orange)
        // 耳朵
        px(11, 13, 1, 2, dark)
        px(13, 13, 1, 2, dark)
        // 眼睛
        px(13, 11, 1, 1, dark)
        // 鼻头
        px(14, 10, 1, 1, pink)

        // 四条腿（y5..y7，两帧前后交错）
        let legs = [4 + legShift, 6 - legShift, 9 + legShift, 11 - legShift]
        for lx in legs {
            px(lx, 5, 1, 3, orange)
            px(lx, 5, 1, 1, white)   // 爪尖
        }
    }

    /// 睡觉：蜷成团 + 闭眼 + 尾巴圈住 + 头顶冒 Z
    private static func drawSleeping() {
        // 身体（y6..y10，底部垫一行做圆角感）
        px(4, 6, 9, 4, orange)
        px(5, 5, 7, 1, orange)
        // 头埋在右侧
        px(9, 6, 5, 4, orange)
        px(12, 9, 1, 2, dark)      // 耳朵
        // 闭眼（一条横线）
        px(11, 7, 2, 1, dark)
        // 尾巴圈住前面
        px(3, 5, 8, 1, dark)

        // 头顶冒 Z
        px(14, 12, 1, 1, dark)
        px(13, 11, 2, 1, dark)
        px(14, 10, 1, 1, dark)
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
