import AppKit
import Carbon.HIToolbox

/// RegisterEventHotKey can return noErr even for combinations claimed by macOS,
/// so registration alone cannot identify conflicts. Compare against the system
/// shortcut table instead.
enum SystemHotKeys {
    private static let cocoaCmd = 1 << 20
    private static let cocoaOpt = 1 << 19
    private static let cocoaShift = 1 << 17
    private static let cocoaCtrl = 1 << 18

    /// Converts Carbon modifier bits to the Cocoa bits used by the system shortcut table.
    private static func cocoaModifiers(_ spec: HotKeySpec) -> Int {
        var m = 0
        if spec.modifiers & UInt32(cmdKey) != 0 { m |= cocoaCmd }
        if spec.modifiers & UInt32(optionKey) != 0 { m |= cocoaOpt }
        if spec.modifiers & UInt32(shiftKey) != 0 { m |= cocoaShift }
        if spec.modifiers & UInt32(controlKey) != 0 { m |= cocoaCtrl }
        return m
    }

    /// All enabled system shortcuts as `(keyCode, cocoaModifiers)`.
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
            // Retain only the four modifier bits recognized by this app.
            let cleaned = modifiers & (cocoaCmd | cocoaOpt | cocoaShift | cocoaCtrl)
            result.append((keyCode, cleaned))
        }
        return result
    }

    /// Returns targets whose shortcuts conflict with system shortcuts.
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
