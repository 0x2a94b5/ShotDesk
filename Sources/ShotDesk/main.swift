import AppKit

let app = NSApplication.shared
// No Dock icon and no participation in the application switcher.
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
