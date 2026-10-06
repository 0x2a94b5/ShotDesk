import AppKit
import Carbon.HIToolbox

/// 从窗口四边向内裁掉的点数。
/// 为什么用点数而不是百分比：浏览器的标签栏/地址栏/书签栏、应用的工具栏，
/// 高度都是**固定点数**，不随窗口大小变化。按百分比裁，窗口一拉高就裁错位置。
struct CropInsets: Codable, Equatable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = max(0, top)
        self.left = max(0, left)
        self.bottom = max(0, bottom)
        self.right = max(0, right)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
        left = try c.decodeIfPresent(Double.self, forKey: .left) ?? 0
        bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
        right = try c.decodeIfPresent(Double.self, forKey: .right) ?? 0
    }

    var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }

    /// 按图像缩放系数换算成像素裁剪框
    func cropRect(imageWidth: Int, imageHeight: Int, scale: Double) -> CGRect {
        CGRect(x: left * scale,
               y: top * scale,
               width: Double(imageWidth) - (left + right) * scale,
               height: Double(imageHeight) - (top + bottom) * scale).integral
    }
}

struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon 修饰键位：cmdKey / optionKey / shiftKey / controlKey
    var modifiers: UInt32

    static func optCmd(_ keyCode: UInt32) -> HotKeySpec {
        HotKeySpec(keyCode: keyCode, modifiers: UInt32(optionKey | cmdKey))
    }

    var cocoaFlags: NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    /// 给人看的组合描述，如 "⌥⌘1"
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyEquivalent.uppercased()
    }

    /// 菜单项右侧显示用的字符
    var keyEquivalent: String {
        HotKeySpec.keyCodeChars[keyCode].map(String.init) ?? ""
    }

    private static let keyCodeChars: [UInt32: Character] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t",
        32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z"
    ]
}

struct CaptureTarget: Codable, Equatable {
    var id: String
    var label: String
    /// 首选匹配方式：bundle identifier，最稳
    var bundleID: String?
    /// 备用匹配方式：进程名。注意系统返回的可能带 ".app" 后缀，匹配做了归一化。
    /// bundleID 和 ownerName 都为 nil = 当前最前窗口
    var ownerName: String?
    /// 窗口标题子串，用于在多个 Chrome 窗口里挑出对的那个
    var titleContains: String?
    /// 浏览器标签页匹配串（匹配标题或网址）。设了它就会在抓图前
    /// 用 AppleScript 把该标签切到前台——Chrome 窗口标题只反映当前激活标签，
    /// 目标在后台标签时光靠 titleContains 是找不到的。
    var tabMatch: String?
    /// 从窗口四边裁掉的点数，用于去掉浏览器工具栏之类的固定高度装饰
    var insets: CropInsets?
    /// 抓前先把目标窗口激活。被遮挡的窗口会被系统节流渲染，
    /// 不激活可能抓到过期的 K 线 —— 对行情分析是致命的。
    var activateBeforeCapture: Bool
    var hotKey: HotKeySpec?

    /// 没有任何应用限定，抓当前最前窗口
    var isFrontmost: Bool { bundleID == nil && ownerName == nil }

    /// 菜单里显示的应用名
    var appLabel: String { ownerName ?? bundleID ?? "最前窗口" }

    init(id: String, label: String, bundleID: String? = nil, ownerName: String? = nil,
         titleContains: String? = nil, tabMatch: String? = nil, insets: CropInsets? = nil,
         activateBeforeCapture: Bool = true, hotKey: HotKeySpec?) {
        self.id = id
        self.label = label
        self.bundleID = bundleID
        self.ownerName = ownerName
        self.titleContains = titleContains
        self.tabMatch = tabMatch
        self.insets = insets
        self.activateBeforeCapture = activateBeforeCapture
        self.hotKey = hotKey
    }

    /// 配置文件是给人手改的，缺字段要能容错
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        titleContains = try c.decodeIfPresent(String.self, forKey: .titleContains)
        tabMatch = try c.decodeIfPresent(String.self, forKey: .tabMatch)
        insets = try c.decodeIfPresent(CropInsets.self, forKey: .insets)
        activateBeforeCapture = try c.decodeIfPresent(Bool.self, forKey: .activateBeforeCapture) ?? true
        hotKey = try c.decodeIfPresent(HotKeySpec.self, forKey: .hotKey)
    }
}

struct AppConfig: Codable {
    var targets: [CaptureTarget]
    var saveToDisk: Bool
    var saveDirectory: String
    /// 抓取成功播放系统快门音。纯剪贴板输出没有任何视觉变化，
    /// 只靠菜单栏图标闪一下根本注意不到，声音才是可靠的反馈。
    var playSound: Bool
    /// 手动框选截图的热键。这是主力路径，独立于按应用抓取的那些目标。
    var regionHotKey: HotKeySpec?

    init(targets: [CaptureTarget], saveToDisk: Bool, saveDirectory: String,
         playSound: Bool = true, regionHotKey: HotKeySpec? = .optCmd(21)) {
        self.targets = targets
        self.saveToDisk = saveToDisk
        self.saveDirectory = saveDirectory
        self.playSound = playSound
        self.regionHotKey = regionHotKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = try c.decodeIfPresent([CaptureTarget].self, forKey: .targets) ?? AppConfig.standard.targets
        saveToDisk = try c.decodeIfPresent(Bool.self, forKey: .saveToDisk) ?? false
        saveDirectory = try c.decodeIfPresent(String.self, forKey: .saveDirectory) ?? AppConfig.defaultSaveDirectory
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? true
        regionHotKey = try c.decodeIfPresent(HotKeySpec.self, forKey: .regionHotKey) ?? .optCmd(21)
    }

    /// Chrome 顶部装饰（标签栏 40 + 地址栏 40 + 书签栏 41）的实测高度。
    /// 是从真实截图逐行找分隔线量出来的，不是估的。隐藏书签栏的话约 81。
    static let chromeChromeInsets = CropInsets(top: 121)

    static var defaultSaveDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/ShotDesk")
    }

    static let standard = AppConfig(
        targets: [
            CaptureTarget(id: "tradingview", label: "抓 TradingView",
                          bundleID: "com.tradingview.tradingviewapp.desktop",
                          ownerName: "TradingView", hotKey: .optCmd(18)),
            CaptureTarget(id: "coinglass", label: "抓 Coinglass (Chrome)",
                          bundleID: "com.google.Chrome", ownerName: "Google Chrome",
                          titleContains: "Coinglass", tabMatch: "coinglass",
                          insets: AppConfig.chromeChromeInsets,
                          hotKey: .optCmd(19)),
            CaptureTarget(id: "frontmost", label: "抓当前最前窗口",
                          activateBeforeCapture: false, hotKey: .optCmd(20))
        ],
        saveToDisk: false,
        saveDirectory: AppConfig.defaultSaveDirectory,
        playSound: true,
        regionHotKey: .optCmd(21)
    )
}

enum ConfigStore {
    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ShotDesk", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .standard
        }
        return cfg
    }

    @discardableResult
    static func save(_ config: AppConfig) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(config).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
