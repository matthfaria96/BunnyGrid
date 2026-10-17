import AppKit
import CoreImage
// Usage: background <out dir> — full-bleed 1024 background in the artwork's palette (no rim, no shadow: the system adds those).
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let S = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func layer(_ draw: (CGContext) -> Void) -> CIImage {
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin like a design canvas.
    ctx.translateBy(x: 0, y: CGFloat(S)); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return CIImage(cgImage: ctx.makeImage()!)
}
func radial(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: srgb, colors: [color(hex, a), color(hex, a * 0.45), color(hex, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}
func render(dark: Bool) -> CIImage {
    let k: CGFloat = dark ? 0.6 : 1
    let extent = CGRect(x: 0, y: 0, width: S, height: S)
    let base = layer { ctx in
        let g = CGGradient(colorsSpace: srgb, colors: dark
            ? [color(0x1B1A2C), color(0x0C0D14), color(0x120F22)] as CFArray
            : [color(0x3A3858), color(0x1E2030), color(0x2A2346)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: S, y: S), options: [])
        radial(ctx, CGPoint(x: -120, y: 700), 640, 0x8B3DFF, 1.0 * k)   // violet, left
        radial(ctx, CGPoint(x: 260, y: 1150), 520, 0x6A3CFF, 0.85 * k)  // indigo, bottom left
        radial(ctx, CGPoint(x: 1120, y: -60), 600, 0x2AA4FF, 1.0 * k)   // azure, top right
        radial(ctx, CGPoint(x: 1150, y: 700), 360, 0x4A62FF, 0.40 * k)  // blue, right edge
    }
    // Glass waves: filled sweeps with a soft but readable edge.
    func sweep(_ blur: Double, _ draw: @escaping (CGContext) -> Void) -> CIImage {
        layer(draw).applyingGaussianBlur(sigma: blur).cropped(to: extent)
    }
    let upper = sweep(10) { ctx in   // lilac haze above the first wave (top left)
        ctx.beginPath(); ctx.move(to: CGPoint(x: -20, y: -20)); ctx.addLine(to: CGPoint(x: 860, y: -20))
        ctx.addCurve(to: CGPoint(x: -20, y: 470), control1: CGPoint(x: 600, y: 160), control2: CGPoint(x: 230, y: 260))
        ctx.closePath(); ctx.clip()
        let g = CGGradient(colorsSpace: srgb, colors: [color(0x8F8BC8, 0.42 * k), color(0x6C5FD0, 0.18 * k)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 400, y: 420), options: [])
    }
    let lower = sweep(12) { ctx in   // violet wave rising from the bottom
        ctx.beginPath(); ctx.move(to: CGPoint(x: -20, y: 1044)); ctx.addLine(to: CGPoint(x: -20, y: 560))
        ctx.addCurve(to: CGPoint(x: 700, y: 1044), control1: CGPoint(x: 120, y: 760), control2: CGPoint(x: 420, y: 900))
        ctx.closePath(); ctx.clip()
        let g = CGGradient(colorsSpace: srgb, colors: [color(0x9A5BFF, 0.40 * k), color(0x5136D8, 0.30 * k)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 600, y: 1044), options: [])
    }
    let right = sweep(10) { ctx in   // azure wave down the right edge
        ctx.beginPath(); ctx.move(to: CGPoint(x: 640, y: -20)); ctx.addLine(to: CGPoint(x: 1044, y: -20)); ctx.addLine(to: CGPoint(x: 1044, y: 640))
        ctx.addCurve(to: CGPoint(x: 640, y: -20), control1: CGPoint(x: 940, y: 380), control2: CGPoint(x: 820, y: 120))
        ctx.closePath(); ctx.clip()
        let g = CGGradient(colorsSpace: srgb, colors: [color(0x4FC3FF, 0.45 * k), color(0x2F6BFF, 0.15 * k)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 1024, y: 0), end: CGPoint(x: 760, y: 420), options: [])
    }
    let lines = sweep(1.2) { ctx in  // thin light edges along the waves
        ctx.setLineCap(.round)
        ctx.beginPath(); ctx.move(to: CGPoint(x: 860, y: -20))
        ctx.addCurve(to: CGPoint(x: -20, y: 470), control1: CGPoint(x: 600, y: 160), control2: CGPoint(x: 230, y: 260))
        ctx.setStrokeColor(color(0xCFD8FF, 0.30 * k)); ctx.setLineWidth(2.5); ctx.strokePath()
        ctx.beginPath(); ctx.move(to: CGPoint(x: -20, y: 560))
        ctx.addCurve(to: CGPoint(x: 700, y: 1044), control1: CGPoint(x: 120, y: 760), control2: CGPoint(x: 420, y: 900))
        ctx.setStrokeColor(color(0xD7B8FF, 0.30 * k)); ctx.setLineWidth(2.5); ctx.strokePath()
        ctx.beginPath(); ctx.move(to: CGPoint(x: 1044, y: 640))
        ctx.addCurve(to: CGPoint(x: 640, y: -20), control1: CGPoint(x: 940, y: 380), control2: CGPoint(x: 820, y: 120))
        ctx.setStrokeColor(color(0xB8E8FF, 0.35 * k)); ctx.setLineWidth(2.5); ctx.strokePath()
    }
    return lines.composited(over: right.composited(over: lower.composited(over: upper.composited(over: base)))).cropped(to: extent)
}
let ctx = CIContext()
for (dark, name) in [(false, "background.png"), (true, "background-dark.png")] {
    try! ctx.writePNGRepresentation(of: render(dark: dark), to: out.appending(path: name), format: .RGBA8, colorSpace: srgb)
    print("wrote", name)
}
