import AppKit

/// Chrome 窗口的标题只反映**当前激活的标签页**，Coinglass 在后台标签时
/// 按标题根本匹配不到。所以抓图前先用 AppleScript 把目标标签切到前台。
enum BrowserTab {
    enum Outcome {
        case switched          // 找到并切换成功
        case notFound          // 所有窗口里都没有匹配的标签
        case notAuthorized     // 用户拒绝了自动化权限
        case failed(String)

        var note: String? {
            switch self {
            case .switched: return nil
            case .notFound: return nil   // 由调用方结合标题匹配结果给提示
            case .notAuthorized:
                return "没有控制浏览器的权限，无法自动切换标签页。请到 系统偏好设置 → 安全性与隐私 → 隐私 → 自动化 里勾选 ShotDesk 对浏览器的控制。"
            case .failed(let msg): return "切换标签页失败：\(msg)"
            }
        }
    }

    /// AppleScript 字符串字面量转义
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 在指定浏览器里找到标题或网址包含 needle 的标签页，激活它并把窗口提到最前。
    /// AppleScript 的 contains 默认不区分大小写。
    static func activate(matching needle: String, bundleID: String) -> Outcome {
        let n = escape(needle)
        let source = """
        tell application id "\(escape(bundleID))"
            repeat with wi from 1 to (count of windows)
                set w to window wi
                repeat with ti from 1 to (count of tabs of w)
                    set t to tab ti of w
                    if (title of t contains "\(n)") or (URL of t contains "\(n)") then
                        set active tab index of w to ti
                        set index of w to 1
                        activate
                        return "switched"
                    end if
                end repeat
            end repeat
            return "notfound"
        end tell
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed("脚本无法创建")
        }
        let result = script.executeAndReturnError(&error)

        if let error = error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743 用户拒绝授权；-600 应用没运行
            if code == -1743 { return .notAuthorized }
            let msg = error[NSAppleScript.errorMessage] as? String ?? "错误码 \(code)"
            return .failed(msg)
        }
        return result.stringValue == "switched" ? .switched : .notFound
    }
}
