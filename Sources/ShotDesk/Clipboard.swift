import AppKit

enum Clipboard {
    /// Write both PNG and TIFF for compatibility with browsers, Preview, and AI inputs.
    static func put(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    /// Optional archive path: ~/Pictures/ShotDesk/YYYY-MM-DD/<target>-HHmmss.png.
    @discardableResult
    static func saveToDisk(_ image: CGImage, targetID: String, directory: String) -> URL? {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HHmmss"
        let now = Date()

        let dir = URL(fileURLWithPath: directory).appendingPathComponent(day.string(from: now))
        let url = dir.appendingPathComponent("\(targetID)-\(time.string(from: now)).png")

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
