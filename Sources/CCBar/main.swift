import Cocoa

// 主程序入口
let app = NSApplication.shared
// 强制深色模式
app.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
