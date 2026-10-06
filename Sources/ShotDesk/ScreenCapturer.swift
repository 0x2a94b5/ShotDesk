import AppKit

enum CaptureError: Error {
    case noPermission
    case windowNotFound(String)
    case captureFailed
    case cropFailed

    var message: String {
        switch self {
        case .noPermission:
            return """
            ShotDesk 当前拿不到「屏幕录制」权限。

            · 如果你刚刚已经在系统偏好设置里勾选了 ShotDesk：
              权限要重启进程才生效，点下面的「重新启动 ShotDesk」。

            · 如果重启后还是这个提示：
              说明授权记录对不上了（重新编译过 ShotDesk 会导致这种情况）。
              在终端执行 tccutil reset ScreenCapture com.shotdesk.app
              然后到 系统偏好设置 → 安全性与隐私 → 隐私 → 屏幕录制 重新勾选。

            · 如果从没授权过：
              按上面的路径找到 屏幕录制，解锁后勾选 ShotDesk。
            """
        case .windowNotFound(let label):
            return "没找到「\(label)」的窗口，请确认对应应用已经打开且窗口没有最小化。"
        case .captureFailed:
            return "抓取窗口失败。如果刚授予屏幕录制权限，请重启 ShotDesk 后再试。"
        case .cropFailed:
            return "按区域预设裁剪失败，预设可能已失效。可以在菜单里清除预设后重新框选。"
        }
    }

    /// 只有权限问题值得给一个"重新启动"按钮
    var offersRestart: Bool {
        if case .noPermission = self { return true }
        return false
    }
}

struct CaptureOutcome {
    let image: CGImage
    /// 非致命的提示，例如标题没匹配上
    let note: String?
}

enum ScreenCapturer {
    static func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // 这个调用会触发系统的一次性授权弹窗
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// 纯函数形态，将来做多窗口拼图直接复用
    static func capture(target: CaptureTarget,
                        completion: @escaping (Result<CaptureOutcome, CaptureError>) -> Void) {
        guard hasPermission() else {
            completion(.failure(.noPermission))
            return
        }
        // Chrome 窗口标题只反映当前激活标签，目标在后台标签时必须先切过去
        var tabNote: String?
        var switchedTab = false
        if let tabMatch = target.tabMatch, !tabMatch.isEmpty, let bundleID = target.bundleID {
            let outcome = BrowserTab.activate(matching: tabMatch, bundleID: bundleID)
            switch outcome {
            case .switched:
                switchedTab = true
            case .notFound:
                tabNote = "没找到含「\(tabMatch)」的标签页，抓的是当前标签"
            case .notAuthorized, .failed:
                tabNote = outcome.note
            }
        }

        guard let match = WindowFinder.find(target) else {
            completion(.failure(.windowNotFound(target.label)))
            return
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        let shouldRestore = previousApp?.processIdentifier != getpid()
            && previousApp?.processIdentifier != match.ownerPID

        let grab = {
            // 激活后窗口可能移动或换了大小，重新解析一次
            let current = WindowFinder.find(target) ?? match
            defer {
                if shouldRestore { previousApp?.activate(options: [.activateIgnoringOtherApps]) }
            }

            // .boundsIgnoreFraming 去掉窗口阴影，图不带一圈半透明边
            guard let full = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                     current.windowID,
                                                     [.boundsIgnoreFraming, .bestResolution]) else {
                completion(.failure(.captureFailed))
                return
            }

            // 切过标签就不必再抱怨标题没匹配上——那是同一件事的两种说法
            var note = tabNote
            if note == nil, !switchedTab,
               target.titleContains?.isEmpty == false, !current.titleMatched {
                note = "未匹配到标题「\(target.titleContains!)」，抓的是 \(current.ownerName) 最前窗口"
            }

            guard let insets = target.insets, !insets.isZero else {
                completion(.success(CaptureOutcome(image: full, note: note)))
                return
            }
            // 窗口点数 → 图像像素的倍率（Retina 屏是 2）
            let scale = Double(full.width) / Double(current.bounds.width)
            let px = insets.cropRect(imageWidth: full.width, imageHeight: full.height, scale: scale)
            guard px.width >= 1, px.height >= 1, let cropped = full.cropping(to: px) else {
                completion(.failure(.cropFailed))
                return
            }
            completion(.success(CaptureOutcome(image: cropped, note: note)))
        }

        if target.activateBeforeCapture,
           let app = NSRunningApplication(processIdentifier: match.ownerPID),
           !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
            // 一次性延时，不是常驻 timer。切过标签要多等一会儿让页面渲染完
            DispatchQueue.main.asyncAfter(deadline: .now() + (switchedTab ? 0.4 : 0.12), execute: grab)
        } else if switchedTab {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: grab)
        } else {
            grab()
        }
    }
}
