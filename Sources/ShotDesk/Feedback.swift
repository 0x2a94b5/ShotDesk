import AppKit

/// 抓取反馈。纯剪贴板输出屏幕上不会有任何变化，反馈必须足够明显，
/// 否则用户会以为"点了没反应"——实测就发生过。
enum Feedback {
    /// macOS 自带的截图快门音，和系统截图听感一致
    private static let shutterPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"

    /// 预加载一次反复使用，避免每次抓图都读盘
    private static let shutter: NSSound? = {
        guard FileManager.default.fileExists(atPath: shutterPath) else {
            return NSSound(named: "Tink")
        }
        return NSSound(contentsOfFile: shutterPath, byReference: true)
    }()

    static func playShutter() {
        guard let sound = shutter else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
