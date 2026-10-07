import AppKit

struct WindowMatch {
    let windowID: CGWindowID
    /// Global top-left-origin coordinates.
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let title: String?
    /// Whether `titleContains` matched. False means falling back to the app's
    /// frontmost window.
    let titleMatched: Bool
}

enum WindowFinder {
    /// Treat windows smaller than this as panels or dialogs and exclude them.
    private static let minWidth: CGFloat = 200
    private static let minHeight: CGFloat = 150

    /// Prefer matching bundle identifiers; otherwise match process names. System
    /// owner names can include a ".app" suffix, so normalize before comparison.
    private static func matches(target: CaptureTarget, pid: pid_t, ownerName: String) -> Bool {
        if let wantedBundle = target.bundleID, !wantedBundle.isEmpty {
            if let actual = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                return actual.caseInsensitiveCompare(wantedBundle) == .orderedSame
            }
        }
        guard let wantedName = target.ownerName, !wantedName.isEmpty else { return false }
        return normalize(ownerName) == normalize(wantedName)
    }

    private static func normalize(_ name: String) -> String {
        var n = name
        if n.lowercased().hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func find(_ target: CaptureTarget) -> WindowMatch? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let selfPID = getpid()
        var candidates: [WindowMatch] = []

        // The list is front-to-back, so the first candidate is the frontmost window.
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary) else { continue }
            guard bounds.width >= minWidth, bounds.height >= minHeight else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if !target.isFrontmost, !matches(target: target, pid: pid, ownerName: owner) { continue }
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            candidates.append(WindowMatch(windowID: windowID,
                                          bounds: bounds,
                                          ownerPID: pid,
                                          ownerName: owner,
                                          title: info[kCGWindowName as String] as? String,
                                          titleMatched: false))
        }

        guard let first = candidates.first else { return nil }

        if let needle = target.titleContains, !needle.isEmpty {
            if let hit = candidates.first(where: {
                ($0.title ?? "").localizedCaseInsensitiveContains(needle)
            }) {
                return WindowMatch(windowID: hit.windowID, bounds: hit.bounds, ownerPID: hit.ownerPID,
                                   ownerName: hit.ownerName, title: hit.title, titleMatched: true)
            }
        }
        return first
    }
}
