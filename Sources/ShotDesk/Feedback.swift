import AppKit

/// Capture feedback. Clipboard-only output has no visible result, so feedback
/// must be obvious enough that users know the action succeeded.
enum Feedback {
    /// The system screenshot shutter sound.
    private static let shutterPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"

    /// Load once and reuse it instead of reading from disk for every capture.
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
