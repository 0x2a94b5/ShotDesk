import AppKit

/// Chrome window titles only describe the active tab. Use AppleScript to bring
/// a matching target tab forward before capture.
enum BrowserTab {
    enum Outcome {
        case switched          // Found and activated.
        case notFound          // No matching tab in any window.
        case notAuthorized     // The user denied Automation permission.
        case failed(String)

        var note: String? {
            switch self {
            case .switched: return nil
            case .notFound: return nil   // The caller combines this with title matching.
            case .notAuthorized:
                return "没有控制浏览器的权限，无法自动切换标签页。请到 系统偏好设置 → 安全性与隐私 → 隐私 → 自动化 里勾选 ShotDesk 对浏览器的控制。"
            case .failed(let msg): return "切换标签页失败：\(msg)"
            }
        }
    }

    /// Escapes an AppleScript string literal.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Finds a tab whose title or URL contains `needle`, activates it, and brings
    /// its window forward. AppleScript `contains` is case-insensitive by default.
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
            // -1743: Automation permission denied; -600: application not running.
            if code == -1743 { return .notAuthorized }
            let msg = error[NSAppleScript.errorMessage] as? String ?? "错误码 \(code)"
            return .failed(msg)
        }
        return result.stringValue == "switched" ? .switched : .notFound
    }
}
