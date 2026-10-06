import AppKit
import Foundation

private struct IconVariant {
    let pixels: Int
    let filenames: [String]
}

private let variants = [
    IconVariant(pixels: 16, filenames: ["icon_16x16.png"]),
    IconVariant(pixels: 32, filenames: ["icon_16x16@2x.png", "icon_32x32.png"]),
    IconVariant(pixels: 64, filenames: ["icon_32x32@2x.png"]),
    IconVariant(pixels: 128, filenames: ["icon_128x128.png"]),
    IconVariant(pixels: 256, filenames: ["icon_128x128@2x.png", "icon_256x256.png"]),
    IconVariant(pixels: 512, filenames: ["icon_256x256@2x.png", "icon_512x512.png"]),
    IconVariant(pixels: 1024, filenames: ["icon_512x512@2x.png"]),
]

private let arguments = CommandLine.arguments
private let sourcePath = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.png"
private let outputPath = arguments.count > 2 ? arguments[2] : "build/AppIcon.iconset"
private let fileManager = FileManager.default
private let sourceURL = URL(fileURLWithPath: sourcePath)
private let outputURL = URL(fileURLWithPath: outputPath)

guard let source = NSImage(contentsOf: sourceURL),
      let sourceRepresentation = source.representations.max(by: {
          $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
      }) else {
    fputs("无法读取图标源文件：\(sourcePath)\n", stderr)
    exit(1)
}

guard sourceRepresentation.pixelsWide == sourceRepresentation.pixelsHigh else {
    fputs("图标源文件必须为正方形：\(sourceRepresentation.pixelsWide)x\(sourceRepresentation.pixelsHigh)\n", stderr)
    exit(1)
}

guard sourceRepresentation.pixelsWide >= 1024 else {
    fputs("图标源文件至少需要 1024x1024 像素。\n", stderr)
    exit(1)
}

try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

func render(pixels: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "ShotDesk.Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 \(pixels)x\(pixels) 位图"])
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ShotDesk.Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法编码 \(filename)"])
    }
    try data.write(to: outputURL.appendingPathComponent(filename))
}

do {
    for variant in variants {
        for filename in variant.filenames {
            try render(pixels: variant.pixels, filename: filename)
        }
    }
    print("图标资源已生成：\(outputPath)")
} catch {
    fputs("生成图标失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
