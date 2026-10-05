import XCTest
import SQLite3
@testable import CCBar

// MARK: - 设置视图模型
//
// 布局由 SwiftUI 负责（原来 AppKit 手写约束的“行被压塌”类 bug 不复存在），
// 这里锁住行为契约：校验拦截、字段落库、重置回滚、数据源路径回落。

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: Settings!
    private var savedCount = 0
    private var alerts: [(String, String)] = []
    private var launchChanges: [Bool] = []
    private var themeChanges: [Theme] = []

    override func setUp() {
        super.setUp()
        // 断言里用中文原文，钉住语言防 CI locale 漂移
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        suiteName = "ccbar.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Settings(defaults: defaults)
        savedCount = 0
        alerts = []
        launchChanges = []
        themeChanges = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        super.tearDown()
    }

    private func makeViewModel() -> SettingsViewModel {
        let vm = SettingsViewModel(settings: settings) { [weak self] in self?.savedCount += 1 }
        vm.showAlert = { [weak self] title, body in self?.alerts.append((title, body)) }
        vm.applyLaunchAtLogin = { [weak self] v in self?.launchChanges.append(v) }
        vm.applyTheme = { [weak self] t in self?.themeChanges.append(t) }
        return vm
    }

    func testSaveRejectsInvalidNumbers() {
        let vm = makeViewModel()
        vm.refreshIntervalText = "abc"
        vm.warningThresholdText = "-1"
        vm.save()

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].0, "无法保存")
        XCTAssertTrue(alerts[0].1.contains("刷新间隔"))
        XCTAssertTrue(alerts[0].1.contains("预警阈值"))
        XCTAssertEqual(savedCount, 0, "校验失败不得回调保存")
        XCTAssertEqual(settings.refreshInterval, 30, "校验失败不得写入")
    }

    func testSaveRejectsOutOfRangeInterval() {
        let vm = makeViewModel()
        vm.refreshIntervalText = "3"
        vm.save()
        XCTAssertEqual(alerts.first?.0, "无法保存")

        vm.refreshIntervalText = "5"
        vm.save()
        XCTAssertEqual(alerts.last?.0, "设置已保存")
        XCTAssertEqual(settings.refreshInterval, 5)
    }

    func testSaveAppliesAllFields() {
        let vm = makeViewModel()
        vm.refreshIntervalText = "60"
        vm.warningThresholdText = "80"
        vm.notifyIntervalText = "0"
        vm.ledThresholdText = "200"
        vm.warningEnabled = false
        vm.menuPetEnabled = false
        vm.menuEmojiEnabled = false
        vm.popoverWide = true
        vm.theme = Theme.crt
        if let i = vm.sources.firstIndex(where: { $0.id == "zcode" }) {
            vm.sources[i].enabled = true
            vm.sources[i].path = "/tmp/fake-zcode.db"
        }
        vm.save()

        XCTAssertEqual(alerts.last?.0, "设置已保存")
        XCTAssertEqual(savedCount, 1)
        XCTAssertEqual(settings.refreshInterval, 60)
        XCTAssertEqual(settings.warningThreshold, 80)
        XCTAssertEqual(settings.notifyInterval, 0)
        XCTAssertEqual(settings.ledRedThreshold, 200)
        XCTAssertFalse(settings.warningEnabled)
        XCTAssertFalse(settings.menuPetEnabled)
        XCTAssertFalse(settings.menuEmojiEnabled)
        XCTAssertTrue(settings.popoverWide)
        XCTAssertEqual(themeChanges, [.crt], "主题只落点一次")

        let zc = settings.sourceConfigs.first { $0.id == "zcode" }
        XCTAssertEqual(zc?.enabled, true)
        XCTAssertEqual(zc?.dbPath, "/tmp/fake-zcode.db")
    }

    func testSourcePathEmptyFallsBackToDefault() {
        let vm = makeViewModel()
        if let i = vm.sources.firstIndex(where: { $0.id == "ccswitch" }) {
            vm.sources[i].enabled = true
            vm.sources[i].path = "   "
        }
        vm.save()

        let cc = settings.sourceConfigs.first { $0.id == "ccswitch" }
        XCTAssertEqual(cc?.enabled, true)
        XCTAssertEqual(cc?.dbPath, CCSwitchAdapter().defaultPath, "留空回落默认路径")
    }

    func testResetRestoresDefaults() {
        let vm = makeViewModel()
        vm.refreshIntervalText = "60"
        vm.warningThresholdText = "80"
        vm.popoverWide = true
        vm.save()
        savedCount = 0

        vm.reset()
        XCTAssertEqual(settings.refreshInterval, 30)
        XCTAssertEqual(settings.warningThreshold, 50)
        XCTAssertFalse(settings.popoverWide)
        XCTAssertEqual(vm.refreshIntervalText, "30", "重置后草稿同步回默认值")
        XCTAssertEqual(vm.warningThresholdText, "50")
        XCTAssertEqual(savedCount, 0, "重置不触发保存回调")
        XCTAssertEqual(launchChanges, [false, false], "重置关闭开机启动但不惊动系统")
    }

    func testValidateDB() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let good = dir + "/good.db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(good, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE proxy_request_logs (id INTEGER)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE usage_daily_rollups (id INTEGER)", nil, nil, nil)
        sqlite3_close(db)

        let bare = dir + "/bare.db"
        XCTAssertEqual(sqlite3_open(bare, &db), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertNil(SettingsViewModel.validateDB(path: good,
                                                  requiredTables: CCSwitchAdapter().requiredTables))
        XCTAssertEqual(SettingsViewModel.validateDB(path: bare,
                                                    requiredTables: CCSwitchAdapter().requiredTables),
                       "缺少必需表")
        XCTAssertEqual(SettingsViewModel.validateDB(path: dir + "/missing.db",
                                                    requiredTables: CCSwitchAdapter().requiredTables),
                       "打不开（被占用或损坏）")
    }
}
