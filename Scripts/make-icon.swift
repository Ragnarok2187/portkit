// Draws the PortKit app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift [output.icns]
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = CGFloat(px) / 1024
    cg.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt tile centered in 1024, ~185pt corner radius, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(tilePath)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Background: deep indigo → electric violet → hot pink.
    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let colors = [NSColor(srgbRed: 0.10, green: 0.09, blue: 0.32, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.42, green: 0.20, blue: 0.95, alpha: 1).cgColor,
                  NSColor(srgbRed: 1.00, green: 0.36, blue: 0.62, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 160, y: 100), end: CGPoint(x: 880, y: 924), options: [])

    // A sweeping "port" arc behind the controller: the hand-off from one platform to another.
    cg.setLineCap(.round)
    cg.setLineWidth(46)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.addArc(center: CGPoint(x: 512, y: 470), radius: 330, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
    cg.strokePath()
    // Arrowhead continuing the arc's direction of travel at its left end.
    let theta = CGFloat.pi * 0.85
    let end = CGPoint(x: 512 + 330 * cos(theta), y: 470 + 330 * sin(theta))
    let dir = CGPoint(x: -sin(theta), y: cos(theta))   // counter-clockwise tangent
    let perp = CGPoint(x: -dir.y, y: dir.x)
    cg.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.move(to: CGPoint(x: end.x + dir.x * 100, y: end.y + dir.y * 100))
    cg.addLine(to: CGPoint(x: end.x + perp.x * 52 - dir.x * 20, y: end.y + perp.y * 52 - dir.y * 20))
    cg.addLine(to: CGPoint(x: end.x - perp.x * 52 - dir.x * 20, y: end.y - perp.y * 52 - dir.y * 20))
    cg.closePath()
    cg.fillPath()
    cg.restoreGState()

    // Controller body: a wide capsule with two grips, drawn as one union shape.
    let body = CGMutablePath()
    body.addRoundedRect(in: CGRect(x: 232, y: 360, width: 560, height: 250), cornerWidth: 125, cornerHeight: 125)
    body.addEllipse(in: CGRect(x: 222, y: 250, width: 210, height: 300))
    body.addEllipse(in: CGRect(x: 592, y: 250, width: 210, height: 300))
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.addPath(body)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // D-pad.
    let ink = NSColor(srgbRed: 0.20, green: 0.13, blue: 0.55, alpha: 1).cgColor
    cg.setFillColor(ink)
    let dp = CGPoint(x: 360, y: 470)
    cg.addPath(CGPath(roundedRect: CGRect(x: dp.x - 70, y: dp.y - 22, width: 140, height: 44), cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.addPath(CGPath(roundedRect: CGRect(x: dp.x - 22, y: dp.y - 70, width: 44, height: 140), cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.fillPath()

    // Face buttons in the accent colors.
    let bp = CGPoint(x: 664, y: 470)
    let buttons: [(CGFloat, CGFloat, NSColor)] = [
        (0, 52, NSColor(srgbRed: 1.00, green: 0.36, blue: 0.62, alpha: 1)),
        (52, 0, NSColor(srgbRed: 0.42, green: 0.20, blue: 0.95, alpha: 1)),
        (0, -52, NSColor(srgbRed: 0.20, green: 0.13, blue: 0.55, alpha: 1)),
        (-52, 0, NSColor(srgbRed: 0.98, green: 0.65, blue: 0.20, alpha: 1)),
    ]
    for (dx, dy, color) in buttons {
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: CGRect(x: bp.x + dx - 27, y: bp.y + dy - 27, width: 54, height: 54))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// PNG-backed ICNS entries for each size Finder and the Dock ask for.
let entries: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("icp6", 64), ("ic12", 64), ("ic07", 128),
                                ("ic08", 256), ("ic13", 256), ("ic09", 512), ("ic14", 512), ("ic10", 1024)]
func be32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
var body = Data()
var cache: [Int: Data] = [:]
for (type, px) in entries {
    let png = cache[px] ?? render(px)
    cache[px] = png
    body += Data(type.utf8) + be32(8 + png.count) + png
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
try! (Data("icns".utf8) + be32(8 + body.count) + body).write(to: URL(fileURLWithPath: out))
try! cache[1024]!.write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print("Wrote \(out)")
