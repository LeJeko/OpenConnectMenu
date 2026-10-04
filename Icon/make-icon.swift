// Generates the app icon (red tunnel): AppIcon.iconset, AppIcon.icns and a 1024 px preview.
//   swift Icon/make-icon.swift Icon        (from the project root)
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon"
let iconset = "\(outDir)/AppIcon.iconset"

// Drawing designed on a 150-unit tile, scaled up onto the 824 px body of the 1024 px canvas
// (100 px margin around it, like the macOS icon template).
let canvas = 1024.0, margin = 100.0
let body = canvas - 2 * margin
let k = body / 150.0
func X(_ x: Double) -> Double { margin + x * k }
func Y(_ y: Double) -> Double { canvas - (margin + y * k) }   // origin at the bottom left

let red = CGColor(srgbRed: 0xA6 / 255, green: 0x1B / 255, blue: 0x1B / 255, alpha: 1)

/// macOS icon shape: superellipse (exponent ~5), closer to Apple's "squircle" than a plain rounded rectangle.
func squircle(in rect: CGRect, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    let steps = 240
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// Arch: two vertical posts joined by a semicircle (coordinates of the 150 tile).
func arch(cx: Double, top: Double, radius r: Double, bottom: Double, close: Bool = false) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: X(cx - r), y: Y(bottom)))
    p.addLine(to: CGPoint(x: X(cx - r), y: Y(top)))
    p.addArc(center: CGPoint(x: X(cx), y: Y(top)), radius: r * k,
             startAngle: .pi, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: X(cx + r), y: Y(bottom)))
    if close { p.closeSubpath() }
    return p
}

func draw(_ ctx: CGContext) {
    // Icon body with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.30))
    ctx.setFillColor(red)
    ctx.addPath(squircle(in: CGRect(x: margin, y: margin, width: body, height: body)))
    ctx.fillPath()
    ctx.restoreGState()

    let white = CGColor(gray: 1, alpha: 1)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(9 * k)

    // Outer arch
    ctx.setStrokeColor(white)
    ctx.addPath(arch(cx: 75, top: 76, radius: 43, bottom: 118))
    ctx.strokePath()

    // Middle arch
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.65))
    ctx.addPath(arch(cx: 75, top: 80, radius: 25, bottom: 118))
    ctx.strokePath()

    // Light at the end of the tunnel
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.40))
    ctx.addPath(arch(cx: 75, top: 90, radius: 12, bottom: 118, close: true))
    ctx.fillPath()

    // Ground, aligned with the outer edge of the posts (32 - 9/2 = 27.5)
    ctx.setFillColor(white)
    let bar = CGRect(x: X(27.5), y: Y(126), width: 95 * k, height: 8 * k)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 4 * k, cornerHeight: 4 * k, transform: nil))
    ctx.fillPath()
}

func png(size: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: Double(size) / canvas, y: Double(size) / canvas)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// Sizes required by iconutil: (name, size in pixels)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try png(size: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try png(size: 1024).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-1024.png"))
print("✔ \(iconset) et \(outDir)/AppIcon-1024.png")
