import AppKit
import Carbon.HIToolbox

/// Point insets cropped from each edge of a window. Browser chrome and app
/// toolbars have fixed point heights, so point insets remain correct as a
/// window is resized while percentage-based cropping does not.
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

    /// Converts the insets to a pixel crop rectangle at the image scale.
    func cropRect(imageWidth: Int, imageHeight: Int, scale: Double) -> CGRect {
        CGRect(x: left * scale,
               y: top * scale,
               width: Double(imageWidth) - (left + right) * scale,
               height: Double(imageHeight) - (top + bottom) * scale).integral
    }
}

struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier bits: cmdKey / optionKey / shiftKey / controlKey.
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

    /// A human-readable combination such as "⌥⌘1".
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyEquivalent.uppercased()
    }

    /// The character shown at the right of a menu item.
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
    /// Preferred and most reliable match: bundle identifier.
    var bundleID: String?
    /// Fallback match: process name. System results can include a ".app" suffix,
    /// so values are normalized before comparison. Both nil means the frontmost window.
    var ownerName: String?
    /// A window-title substring used to select the intended Chrome window.
    var titleContains: String?
    /// A browser-tab match string for title or URL. When set, AppleScript brings
    /// the tab forward before capture because Chrome titles only expose the active tab.
    var tabMatch: String?
    /// Point insets used to remove fixed-height chrome such as a browser toolbar.
    var insets: CropInsets?
    /// Activates the target before capture. macOS can throttle rendering of
    /// occluded windows, which otherwise risks capturing stale chart data.
    var activateBeforeCapture: Bool
    var hotKey: HotKeySpec?

    /// No app restriction: capture the frontmost window.
    var isFrontmost: Bool { bundleID == nil && ownerName == nil }

    /// The application name shown in the menu.
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

    /// The configuration file is hand-editable, so missing fields must be tolerated.
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
    /// Plays the system shutter sound on a successful capture. Clipboard-only
    /// output has little visible feedback, so sound provides a reliable signal.
    var playSound: Bool
    /// The primary free-region capture shortcut, independent of app-specific targets.
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

    /// Measured Chrome top-chrome height: tabs 40 + address bar 40 + bookmarks 41.
    /// It is measured from real screenshots; with bookmarks hidden it is about 81.
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
