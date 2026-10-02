import XCTest
@testable import CCBar

// MARK: - 设置窗口布局回归

/// 回归背景：数据源行的内部布局约束一度不完整（row 未钉住 container 的
/// top/leading/trailing），内容栈被放进滚动视图后整行被压塌成空白。
/// 这里强制布局后逐行检查几何，防止同类问题再溜进来。
final class SettingsLayoutTests: XCTestCase {

    private func makeLaidOutController() -> SettingsWindowController {
        let controller = SettingsWindowController(settings: Settings(), onSave: {})
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    /// 滚动视图里的内容栈（documentView）
    private func contentStack(of controller: SettingsWindowController) -> NSStackView? {
        for sub in controller.window?.contentView?.subviews ?? [] {
            guard let scroll = sub as? NSScrollView,
                  let stack = scroll.documentView as? NSStackView else { continue }
            return stack
        }
        return nil
    }

    func testAllRowsLaidOutNonOverlapping() {
        let controller = makeLaidOutController()
        guard let stack = contentStack(of: controller) else {
            return XCTFail("设置窗口内容栈不存在")
        }

        var previous: NSView?
        for row in stack.arrangedSubviews {
            XCTAssertGreaterThan(row.frame.height, 0,
                                 "行被压塌: \(row)")
            // 行与行不许互相侵入（贴边不算，坐标方向无关）
            if let prev = previous {
                let overlap = prev.frame.intersection(row.frame)
                XCTAssertTrue(overlap.isNull || overlap.height <= 0.5,
                              "行重叠: \(prev.frame) ∩ \(row.frame)")
            }
            previous = row
        }
    }

    func testSourceRowsVisibleWithFullPathControls() {
        let controller = makeLaidOutController()
        guard let stack = contentStack(of: controller) else {
            return XCTFail("设置窗口内容栈不存在")
        }

        for adapter in SourceRegistry.adapters {
            guard let field = controller.sourceFields[adapter.id],
                  let check = controller.sourceChecks[adapter.id] else {
                XCTFail("数据源 \(adapter.id) 的控件未创建")
                continue
            }
            let container = field.superview!.superview!
            XCTAssertTrue(stack.arrangedSubviews.contains(container),
                          "数据源 \(adapter.id) 行不在内容栈里")

            // 容器有确定高度（勾选行 24 + 状态行），且不许只剩空白
            XCTAssertGreaterThanOrEqual(container.frame.height, 30,
                                        "数据源 \(adapter.id) 行被压塌")
            // 勾选框在行内左端可见
            let row = check.superview!
            XCTAssertLessThanOrEqual(check.frame.minX, 1,
                                     "数据源 \(adapter.id) 勾选框跑出行")
            XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(check.frame),
                          "数据源 \(adapter.id) 勾选框不在行内: \(check.frame)")
            // 路径输入框有实际宽度（上下文里靠 intrinsic 宽度会缩成一条缝）
            XCTAssertGreaterThan(field.frame.width, 80,
                                 "数据源 \(adapter.id) 路径框没有宽度")
            XCTAssertGreaterThan(field.frame.maxX, container.frame.width * 0.3,
                                 "数据源 \(adapter.id) 路径框没有铺开")
        }
    }

    func testButtonBarPinnedBottomAndScrollable() {
        let controller = makeLaidOutController()
        guard let contentView = controller.window?.contentView,
              let stack = contentStack(of: controller) else {
            return XCTFail("设置窗口结构异常")
        }

        // 内容总高大于一屏时可滚动（不许再把整栈压成一屏）
        let clip = stack.enclosingScrollView!.contentView
        XCTAssertGreaterThanOrEqual(stack.frame.height, clip.frame.height - 1,
                                    "内容高度被压缩进可视区")

        // 按钮栏（含“保存”）钉在窗口底部可视区内
        let buttons: [NSStackView] = contentView.subviews.compactMap { $0 as? NSStackView }
        guard let buttonBar = buttons.first else {
            return XCTFail("底部按钮栏不存在")
        }
        let titles = buttonBar.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("保存"), "保存按钮丢失: \(titles)")
        for btn in buttonBar.arrangedSubviews {
            XCTAssertLessThanOrEqual(btn.frame.maxY, contentView.frame.height + 0.5,
                                     "按钮被挤出窗口: \(btn)")
            XCTAssertGreaterThanOrEqual(btn.frame.minY, 0, "按钮在窗口外")
        }
    }
}
