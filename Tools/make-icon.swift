// Generates Resources/AppIcon.icns for Topline.   Run from the repo root:  swift Tools/make-icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, centered, continuous corners.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    // Drop shadow + background gradient (deep indigo → near black).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.17, blue: 0.42, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1)])!
        .draw(in: body, angle: -90)

    // The top bar: a glassy strip across the top with a few icon dots.
    let barH = body.height * 0.16
    let bar = CGRect(x: body.minX, y: body.maxY - barH, width: body.width, height: barH)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.34), NSColor.white.withAlphaComponent(0.16)])!.draw(in: bar, angle: -90)
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(rect: CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: max(1, s * 0.004))).fill()
    let d = barH * 0.36
    for (i, a) in [0.95, 0.7, 0.7].enumerated() {
        NSColor.white.withAlphaComponent(a).setFill()
        let x = bar.maxX - body.width * 0.12 - CGFloat(i) * d * 1.7
        NSBezierPath(ovalIn: CGRect(x: x, y: bar.midY - d / 2, width: d, height: d)).fill()
    }
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: CGRect(x: bar.minX + body.width * 0.09, y: bar.midY - d * 0.4, width: body.width * 0.2, height: d * 0.8),
                 xRadius: d * 0.4, yRadius: d * 0.4).fill()

    // Rising price line with a soft glow + gradient fill.
    let pts: [CGFloat] = [0.30, 0.38, 0.33, 0.47, 0.42, 0.58, 0.52, 0.70]
    let left = body.minX + body.width * 0.12, right = body.maxX - body.width * 0.12
    let bottom = body.minY + body.height * 0.14, top = bar.minY - body.height * 0.10
    func p(_ i: Int) -> CGPoint {
        CGPoint(x: left + (right - left) * CGFloat(i) / CGFloat(pts.count - 1), y: bottom + (top - bottom) * (pts[i] - 0.2) / 0.55)
    }
    let line = NSBezierPath()
    line.move(to: p(0)); (1..<pts.count).forEach { line.line(to: p($0)) }
    let fill = line.copy() as! NSBezierPath
    fill.line(to: CGPoint(x: right, y: body.minY)); fill.line(to: CGPoint(x: left, y: body.minY)); fill.close()
    NSGraphicsContext.saveGraphicsState()
    fill.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.90, blue: 0.55, alpha: 0.45),
                        NSColor(srgbRed: 0.20, green: 0.90, blue: 0.55, alpha: 0)])!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let green = NSColor(srgbRed: 0.30, green: 0.95, blue: 0.60, alpha: 1)
    ctx.setShadow(offset: .zero, blur: s * 0.035, color: green.withAlphaComponent(0.8).cgColor)
    green.setStroke()
    line.lineWidth = s * 0.035; line.lineCapStyle = .round; line.lineJoinStyle = .round
    line.stroke()
    let end = p(pts.count - 1), r = s * 0.035
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try draw(pt * sc).write(to: set.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try draw(512).write(to: root.appendingPathComponent("Resources/icon.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
