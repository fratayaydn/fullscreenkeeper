// Draws the FullscreenKeeper app icon: a green full-screen button with two dark triangles on a slate rounded square.
// Usage: swift scripts/make-icon.swift <project-dir>
// Writes Resources/AppIcon.icns, .build/AppIcon-preview.png and docs/icon.png.
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [UInt32], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors.map { color($0) } as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Drawn on a 1024 canvas, origin bottom-left.
func drawIcon(_ ctx: CGContext) {
    let body = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)

    // Dark slate background, with a soft green glow behind the button.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x2C3440, 0x181E27, 0x0A0D12], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: [color(0x5BE37A, 0.22), color(0x5BE37A, 0)] as CFArray,
                                      locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 430, options: [])
    ctx.restoreGState()

    // A large green window button, shaded vertically with a soft upper highlight.
    let button = CGRect(x: 262, y: 262, width: 500, height: 500)
    ctx.saveGState()
    ctx.addEllipse(in: button)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x6EE787, 0x23A443], [0, 1]),
                           start: CGPoint(x: 512, y: 762), end: CGPoint(x: 512, y: 262), options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: [color(0xD8FFE0, 0.22), color(0xD8FFE0, 0)] as CFArray,
                                      locations: [0, 1])!,
                           startCenter: CGPoint(x: 470, y: 670), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 670), endRadius: 240, options: [])
    ctx.restoreGState()

    ctx.setStrokeColor(color(0x1C8A37))
    ctx.setLineWidth(10)
    ctx.strokeEllipse(in: button.insetBy(dx: 5, dy: 5))

    // Two solid outward triangles, with 210-point legs and a 45-point diagonal gap.
    let triangles = [
        [CGPoint(x: 391, y: 633), CGPoint(x: 601, y: 633), CGPoint(x: 391, y: 423)],
        [CGPoint(x: 633, y: 391), CGPoint(x: 423, y: 391), CGPoint(x: 633, y: 601)]
    ]
    ctx.setFillColor(color(0x0B3A18, 0.9))
    for points in triangles {
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: (points[2].x + points[0].x) / 2, y: (points[2].y + points[0].y) / 2))
        for i in 0..<points.count {
            triangle.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % points.count], radius: 18)
        }
        triangle.closeSubpath()
        ctx.addPath(triangle)
        ctx.fillPath()
    }
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let build = "\(root)/.build"
let iconset = "\(build)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: "\(root)/docs", withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(size), "\(iconset)/icon_\(size)x\(size).png")
    writePNG(render(size * 2), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
let preview = render(1024)
writePNG(preview, "\(build)/AppIcon-preview.png")
writePNG(preview, "\(root)/docs/icon.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(root)/Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
