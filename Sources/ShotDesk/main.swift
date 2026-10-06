import AppKit

let app = NSApplication.shared
// 无 Dock 图标、不参与 App 切换
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
