import AppKit
import Foundation
import ImageIO

// Render the PCL emblem and Mac badge in the standard macOS icon sizes.
// Usage: swift scripts/make-icon.swift /path/AppIcon.iconset [source.ico]
// The original ICO contains 256-pixel artwork; do not upscale the 64-pixel avatar.
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift scripts/make-icon.swift output.iconset [source.ico]\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let original = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : scriptDirectory.appendingPathComponent("../Support/IconSources/AppIcon.ico").standardizedFileURL

guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
      let sourceIndex = (0..<CGImageSourceGetCount(source)).max(by: { lhs, rhs in
          let left = CGImageSourceCopyPropertiesAtIndex(source, lhs, nil) as? [CFString: Any]
          let right = CGImageSourceCopyPropertiesAtIndex(source, rhs, nil) as? [CFString: Any]
          return (left?[kCGImagePropertyPixelWidth] as? Int ?? 0) < (right?[kCGImagePropertyPixelWidth] as? Int ?? 0)
      }), let emblem = CGImageSourceCreateImageAtIndex(source, sourceIndex, nil) else {
    fputs("Cannot read original PCL application icon: \(original.path)\n", stderr)
    exit(1)
}
let image = NSImage(cgImage: emblem, size: NSSize(width: emblem.width, height: emblem.height))
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let pixels = points * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let edge = CGFloat(pixels)
    // Preserve the emblem's alpha, leaving the canvas outside the artwork clear.
    let available = edge * 884 / 1024
    let ratio = min(available / image.size.width, available / image.size.height)
    let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
    image.draw(in: NSRect(x: (edge - size.width) / 2, y: (edge - size.height) / 2 + edge * 0.035,
                         width: size.width, height: size.height), from: .zero,
               operation: .copy, fraction: 1, respectFlipped: false, hints: nil)

    let badge = NSRect(x: edge * 0.22, y: edge * 0.07, width: edge * 0.56, height: edge * 0.24)
    let radius = badge.height / 2
    let outline = NSBezierPath(roundedRect: badge, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.04, green: 0.16, blue: 0.29, alpha: 1).setFill()
    outline.fill()
    NSColor(srgbRed: 0.66, green: 0.86, blue: 1, alpha: 1).setStroke()
    outline.lineWidth = max(0.5, edge * 0.012)
    outline.stroke()
    let label = "Mac" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: edge * 0.19, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let labelSize = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: badge.midX - labelSize.width / 2, y: badge.midY - labelSize.height / 2),
               withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: file, options: .atomic)
}
print("Generated \(sizes.count) PCL Mac icon representations from \(emblem.width)×\(emblem.height) artwork.")
