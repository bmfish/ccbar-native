import XCTest
@testable import CCBar

// MARK: - 主题（结构化定义 + JSON 主题包）

final class ThemeTests: XCTestCase {

    func testBuiltinThemesIntegrity() {
        XCTAssertEqual(Theme.builtins.count, 6, "内置 6 套主题")
        XCTAssertEqual(Set(Theme.builtins.map(\.id)).count, 6, "id 不许重复")
        for theme in Theme.builtins {
            XCTAssertFalse(theme.accentHex.isEmpty)
            XCTAssertEqual(theme.modelHexes.count, 6, "\(theme.name) 模型配色 6 色")
            XCTAssertEqual(theme.trendHexes.count, 3, "\(theme.name) 趋势图标 3 色")
        }
        XCTAssertTrue(Theme.crt.scanlines, "CRT 主题必须带扫描线")
        XCTAssertFalse(Theme.classic.scanlines)
        XCTAssertEqual(Theme.kawaii01.bigNumberWeight, .heavy)
    }

    func testHexParsing() {
        XCTAssertEqual(NSColor(hex: "#E86E45").usingColorSpace(.sRGB)?.redComponent ?? -1,
                       232.0 / 255.0, accuracy: 0.001)
        // 三位缩写展开
        XCTAssertEqual(NSColor(hex: "#F0A").usingColorSpace(.sRGB)?.greenComponent ?? -1,
                       0.0, accuracy: 0.001)
        // 非法输入回落白色，不崩
        let bad = NSColor(hex: "not-a-color").usingColorSpace(.sRGB)
        XCTAssertEqual(bad?.redComponent, 1.0)
        XCTAssertEqual(bad?.greenComponent, 1.0)
    }

    func testUpsertDedupeAndRename() {
        // 清掉此前失败运行可能留下的脏数据
        Theme.customThemes = Theme.customThemes.filter { $0.name != "去重测试" && $0.name != "改名主题" }
        let a = Theme.fromJSON(Data("{\"format\":\"ccbar-theme\",\"name\":\"去重测试\",\"accent\":\"#123456\"}".utf8))!
        let kept = Theme.upsertCustom(a)
        XCTAssertEqual(Theme.customThemes.filter { $0.name == "去重测试" }.count, 1)

        // 同名再导入 → 覆盖更新而非新增（去重）
        var again = a
        again.accentHex = "#ABCDEF"
        let updated = Theme.upsertCustom(again)
        XCTAssertEqual(updated.id, kept.id, "同名覆盖保留原 id")
        XCTAssertEqual(Theme.customThemes.filter { $0.name == "去重测试" }.count, 1)
        XCTAssertEqual(Theme.customThemes.first { $0.id == kept.id }?.accentHex, "#ABCDEF")

        // 重命名
        Theme.renameCustom(id: kept.id, to: "改名主题")
        XCTAssertEqual(Theme.customThemes.first { $0.id == kept.id }?.name, "改名主题")

        // 清理，不污染真实偏好
        Theme.customThemes = Theme.customThemes.filter { $0.id != kept.id }
    }

    func testJSONPackRoundTrip() throws {
        let original = Theme.crt
        let data = try JSONEncoder().encode(original)

        var imported = try XCTUnwrap(Theme.fromJSON(data), "合法包必须能解析")
        XCTAssertEqual(imported.name, original.name)
        XCTAssertEqual(imported.accentHex, original.accentHex)
        XCTAssertEqual(imported.scanlines, original.scanlines)
        XCTAssertTrue(imported.id.hasPrefix("custom-"), "导入包必须重新发 id")

        // 再导出再导入，口径不变
        let again = try XCTUnwrap(Theme.fromJSON(JSONEncoder().encode(imported)))
        XCTAssertEqual(again.accentHex, original.accentHex)
        XCTAssertEqual(again.modelHexes, original.modelHexes)
    }

    func testJSONPackValidation() throws {
        XCTAssertNil(Theme.fromJSON(Data("{\"format\":\"other-pack\"}".utf8)),
                     "format 不对必须拒收")
        // 缺字段回落默认主题，宽容手改
        let partial = Theme.fromJSON(Data("{\"format\":\"ccbar-theme\",\"name\":\"极简\",\"accent\":\"#123456\"}".utf8))
        XCTAssertEqual(partial?.name, "极简")
        XCTAssertEqual(partial?.accentHex, "#123456")
        XCTAssertEqual(partial?.modelHexes.count, 6, "缺 models 回落默认 6 色")
    }
}
