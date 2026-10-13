// Renders the app icon at every size the asset catalog needs, and the extension's icons.
//   swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset Extension/icons
//
// The Zewify dark tile with a download arrow whose shaft is drawn as four stacked segments: the segment map
// that is the signature of a segmented downloader, in Haul's blue.
import AppKit

let args = CommandLine.arguments
let appIconDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "App/Resources/Assets.xcassets/AppIcon.appiconset")
let extensionDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Extension/icons")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws on a 1024-point canvas. `tile` false draws only the glyph on a transparent background (extension icons).
func draw(_ ctx: CGContext, tile: Bool) {
    if tile {
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(path); ctx.setFillColor(color(0x1E1B22)); ctx.fillPath()
        ctx.restoreGState()
    }
    let blue = color(0x1098F4)
    let center: CGFloat = 512
    let scale: CGFloat = tile ? 1 : 1.25
    // Four segments of the shaft, from the top down, with gaps between them.
    let shaftWidth: CGFloat = 150 * scale
    let segment: CGFloat = 78 * scale
    let gap: CGFloat = 30 * scale
    let top: CGFloat = tile ? 760 : 900
    for index in 0..<4 {
        let y = top - CGFloat(index) * (segment + gap) - segment
        let rect = CGRect(x: center - shaftWidth / 2, y: y, width: shaftWidth, height: segment)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 20 * scale, cornerHeight: 20 * scale, transform: nil))
        ctx.setFillColor(index == 3 ? color(0x1098F4, 0.55) : blue)
        ctx.fillPath()
    }
    // The arrowhead below the shaft.
    let headTop = top - 4 * (segment + gap) + gap - 10 * scale
    let headWidth: CGFloat = 420 * scale
    let headHeight: CGFloat = 230 * scale
    let head = CGMutablePath()
    head.move(to: CGPoint(x: center - headWidth / 2, y: headTop))
    head.addLine(to: CGPoint(x: center + headWidth / 2, y: headTop))
    head.addLine(to: CGPoint(x: center, y: headTop - headHeight))
    head.closeSubpath()
    ctx.setLineJoin(.round)
    ctx.setLineWidth(40 * scale)
    ctx.setStrokeColor(blue)
    ctx.setFillColor(blue)
    ctx.addPath(head); ctx.drawPath(using: .fillStroke)
}

func render(_ size: Int, tile: Bool) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx, tile: tile)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size, tile: true).write(to: appIconDir.appendingPathComponent("icon_\(size).png"))
}
for size in [16, 32, 48, 128] {
    try render(size, tile: true).write(to: extensionDir.appendingPathComponent("icon-\(size).png"))
}
let contents = """
{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(to: appIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("icons written")
