import Cocoa

// MARK: - 检查更新（GitHub Releases 对比，无 Sparkle 依赖）
//
// 读取 latest release 的 tag_name 与当前版本做语义化比较；
// 有新版引导打开 Releases 页面下载 DMG。签名公证落地后可平滑升级为 Sparkle。

enum UpdateChecker {
    private static let releasesPageURL = URL(string: "https://github.com/bmfish/ccbar-native/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/bmfish/ccbar-native/releases/latest")!

    /// silent = 静默模式（启动时的定期检查）：有新版才弹，无新版/网络失败不吭声
    static func check(silent: Bool = false) {
        var req = URLRequest(url: apiURL, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            var latest: String?
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latest = (obj["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            }

            DispatchQueue.main.async {
                let alert = NSAlert()
                if let latest = latest, isNewer(latest, than: current) {
                    alert.messageText = String(format: L("发现新版本 v%@"), latest)
                    alert.informativeText = String(format: L("当前版本 v%@。前往 GitHub Releases 下载最新 DMG。"), current)
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: L("前往下载"))
                    alert.addButton(withTitle: L("以后再说"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(releasesPageURL)
                    }
                    return
                }
                guard !silent else { return }
                alert.messageText = "检查更新"
                alert.informativeText = latest != nil
                    ? String(format: L("已经是最新版本（v%@）"), current)
                    : L("检查失败，稍后再试，或直接到 GitHub Releases 页面查看")
                alert.alertStyle = .informational
                alert.addButton(withTitle: L("好的"))
                alert.runModal()
            }
        }.resume()
    }

    /// 语义化版本比较：latest 是否比 current 新
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let l = latest.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}
