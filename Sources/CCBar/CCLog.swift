import Foundation
import os

/// 统一日志入口。NSLog 的动态字符串在 unified log 里会被脱敏成 `<private>`，
/// 这里显式声明 public，方便 `log show` 直接排查同步过程。
func ccLog(_ message: String) {
    os_log("[ccBar] %{public}@", message)
}
