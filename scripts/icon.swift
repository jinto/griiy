// Renders assets/AppIcon.svg into assets/AppIcon.icns (committed; run again after editing the SVG):
//   swift scripts/icon.swift assets/AppIcon.svg /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1]) else { print("can't read \(args[1])"); exit(1) }
try? FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2] + "/" + name))
    }
}
