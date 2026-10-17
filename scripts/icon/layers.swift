import AppKit

// Usage: layers <source.png> <out dir>
// Splits the flat neon artwork (scripts/icon/source.png, 1254 px, full bleed) into two 1024 px layers:
//   bunny.png       the glowing white bunny tube with its original colours, transparent elsewhere
//   background.png  the pink-to-purple gradient with the bunny painted out
// The tube is found by its pale colour, the background under it and its glow is filled in from the surrounding
// gradient, and the bunny layer is the source unblended against that background (white glow, soft alpha).
// The default appearance recomposes the artwork; dark and tinted appearances restyle the layers independently.
let args = CommandLine.arguments
let img = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = URL(fileURLWithPath: args[2])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let N = 1024
let src = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N * 4, space: srgb,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
src.interpolationQuality = .high
src.draw(img, in: CGRect(x: 0, y: 0, width: N, height: N))
let px = src.data!.assumingMemoryBound(to: UInt8.self)   // row 0 = top

func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = min(max((x - e0) / (e1 - e0), 0), 1); return t * t * (3 - 2 * t) }
// Seed: the pale tube (high minimum channel), skipping the cream glow in the top-left corner.
var seed = [Float](repeating: 0, count: N * N)
for i in 0..<(N * N) where (i % N) + (i / N) > 380 {
    let m = min(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2]))
    seed[i] = m > 175 ? 1 : 0
}

// Separable box blur with clamped edges.
func boxBlur(_ a: [Float], _ r: Int) -> [Float] {
    var cur = a
    for pass in 0..<2 {
        var output = [Float](repeating: 0, count: N * N)
        let input = cur
        func idx(_ line: Int, _ k: Int) -> Int { let k = min(max(k, 0), N - 1); return pass == 0 ? line * N + k : k * N + line }
        for line in 0..<N {
            var acc: Float = 0
            for k in -r...r { acc += input[idx(line, k)] }
            for k in 0..<N {
                output[idx(line, k)] = acc / Float(2 * r + 1)
                acc += input[idx(line, k + r + 1)] - input[idx(line, k - r)]
            }
        }
        cur = output
    }
    return cur
}
// Region = tube plus its glow and shadow. Outside it the background is the source; inside it is filled
// coarse-to-fine by normalized convolution from the surrounding gradient.
let grown = boxBlur(boxBlur(seed, 22), 22)
let w = grown.map { $0 < 0.01 ? Float(1) : 0 }
let chans = (0..<3).map { c in (0..<(N * N)).map { Float(px[$0 * 4 + c]) * w[$0] } }
var fill = [[Float]](repeating: [Float](repeating: 0, count: N * N), count: 3)
var filled = [Bool](repeating: false, count: N * N)
for r in [16, 32, 64, 128, 256] {
    var wb = w, cb = chans
    for _ in 0..<3 { wb = boxBlur(wb, r); for c in 0..<3 { cb[c] = boxBlur(cb[c], r) } }
    for i in 0..<(N * N) where !filled[i] && wb[i] > 0.05 {
        for c in 0..<3 { fill[c][i] = cb[c][i] / wb[i] }
        filled[i] = true
    }
}
for c in 0..<3 { fill[c] = boxBlur(boxBlur(fill[c], 12), 12) }
let blend = boxBlur(boxBlur(w.map { 1 - $0 }, 6), 6)
var bg = [[Float]](repeating: [Float](repeating: 0, count: N * N), count: 3)
for c in 0..<3 { for i in 0..<(N * N) { bg[c][i] = Float(px[i * 4 + c]) * (1 - blend[i]) + fill[c][i] * blend[i] } }

// Foreground: unblend each pixel against the filled background towards white, so the glow keeps a soft alpha
// and source ≈ bunny over background. Pixels darker than the background (shadows) stay in neither layer.
var alpha = [Float](repeating: 0, count: N * N)
var fg = [[Float]](repeating: [Float](repeating: 0, count: N * N), count: 3)
for i in 0..<(N * N) {
    var a: Float = 0
    for c in 0..<3 { let b = bg[c][i]; a = max(a, (Float(px[i * 4 + c]) - b) / max(255 - b, 1)) }
    a = min(max(a, 0), 1)
    if a < 0.02 { a = 0 }
    alpha[i] = a
    for c in 0..<3 { fg[c][i] = a > 0 ? min(max(Float(px[i * 4 + c]) - (1 - a) * bg[c][i], 0), 255 * a) : 0 }
}

func write(_ name: String, _ body: (Int) -> (Float, Float, Float, Float)) throws {
    let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func u8(_ v: Float) -> UInt8 { UInt8(min(max(v.rounded(), 0), 255)) }
    for i in 0..<(N * N) {
        let p = body(i)   // premultiplied
        d[i * 4] = u8(p.0); d[i * 4 + 1] = u8(p.1); d[i * 4 + 2] = u8(p.2); d[i * 4 + 3] = u8(p.3 * 255)
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote \(name)")
}
func ch(_ i: Int, _ c: Int) -> Float { Float(px[i * 4 + c]) }
try write("background.png") { i in
    (bg[0][i], bg[1][i], bg[2][i], 1)
}
try write("bunny.png") { i in
    (fg[0][i], fg[1][i], fg[2][i], alpha[i])
}
