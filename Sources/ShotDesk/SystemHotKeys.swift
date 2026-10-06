import AppKit
import Carbon.HIToolbox

/// RegisterEventHotKey 对系统已占用的组合也返回 noErr（实测 ⌘⇧3、⌥⌘D 都能"注册成功"），
/// 注册结果完全不能用来判断冲突。真要知道有没有撞车，只能主动读系统的快捷键表比对。
enum SystemHotKeys {
    private static let cocoaCmd = 1 << 20
    private static let cocoaOpt = 1 << 19
    private static let cocoaShift = 1 << 17
    private static let cocoaCtrl = 1 << 18

    /// 把 Carbon 修饰键位换算成系统快捷键表里用的 Cocoa 位
    private static func cocoaModifiers(_ spec: HotKeySpec) -> Int {
        var m = 0
        if spec.modifiers & UInt32(cmdKey) != 0 { m |= cocoaCmd }
        if spec.modifiers & UInt32(optionKey) != 0 { m |= cocoaOpt }
        if spec.modifiers & UInt32(shiftKey) != 0 { m |= cocoaShift }
        if spec.modifiers & UInt32(controlKey) != 0 { m |= cocoaCtrl }
        return m
    }

    /// 系统里所有已启用的快捷键，(keyCode, cocoaModifiers)
    private static func enabledSystemHotKeys() -> [(Int, Int)] {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let all = defaults.dictionary(forKey: "AppleSymbolicHotKeys") else { return [] }

        var result: [(Int, Int)] = []
        for (_, raw) in all {
            guard let entry = raw as? [String: Any],
                  entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any],
                  params.count >= 3,
                  let keyCode = params[1] as? Int,
                  let modifiers = params[2] as? Int else { continue }
            // 只保留我们认识的四个修饰键位，系统表里还有别的杂位
            let cleaned = modifiers & (cocoaCmd | cocoaOpt | cocoaShift | cocoaCtrl)
            result.append((keyCode, cleaned))
        }
        return result
    }

    /// 返回和系统快捷键撞车的目标
    static func conflicts(in targets: [CaptureTarget]) -> [(target: CaptureTarget, spec: HotKeySpec)] {
        let system = enabledSystemHotKeys()
        guard !system.isEmpty else { return [] }

        return targets.compactMap { target in
            guard let spec = target.hotKey else { return nil }
            let wanted = (Int(spec.keyCode), cocoaModifiers(spec))
            let hit = system.contains { $0.0 == wanted.0 && $0.1 == wanted.1 }
            return hit ? (target, spec) : nil
        }
    }
}
