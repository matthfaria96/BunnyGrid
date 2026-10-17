import AppKit
// Usage: split <subject.png> <out dir>  — coins = warm-yellow pixels of the subject, bunny = the rest.
let args = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let w = rep.pixelsWide, h = rep.pixelsHigh
func make() -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
}
let bunny = make(), coins = make()
let s = rep.bitmapData!, spp = rep.samplesPerPixel, bpr = rep.bytesPerRow
// Coordinates are in the 1024 canvas (top-left origin). Coins: x ≥ 568, y ≥ 545. Paw overlaps their top-left.
var smooth = [Float](repeating: 0, count: w * h)
for y in 0..<h { for x in 0..<w {
    let p = s + y * bpr + x * spp
    guard p[3] > 0, x >= 568, y >= 545 else { continue }
    var k: Float = 1
    do {
        let r = Float(p[0]) / 255, g = Float(p[1]) / 255, b = Float(p[2]) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var hue: Float = 0
        if d > 0.0001 {
            if mx == r { hue = 60 * fmodf((g - b) / d, 6) } else if mx == g { hue = 60 * ((b - r) / d + 2) } else { hue = 60 * ((r - g) / d + 4) }
            if hue < 0 { hue += 360 }
        }
        let sat = mx > 0 ? d / mx : 0
        // Lilac/pink fur (hue 200–355) belongs to the paw; gold and its pale highlights to the coins.
        if sat > 0.04 && (hue > 200 || hue < 8) { k = 0 }
    }
    smooth[y * w + x] = k
}}
// Soften the seam by a pixel.
var soft = smooth
for y in 1..<(h - 1) { for x in 1..<(w - 1) {
    var sum: Float = 0
    for dy in -1...1 { for dx in -1...1 { sum += smooth[(y + dy) * w + x + dx] } }
    soft[y * w + x] = sum / 9
}}
smooth = soft
let bd = bunny.bitmapData!, cd = coins.bitmapData!
for y in 0..<h { for x in 0..<w {
    let p = s + y * bpr + x * spp, i = y * w * 4 + x * 4, k = smooth[y * w + x]
    for c in 0..<3 { bd[i + c] = p[c]; cd[i + c] = p[c] }
    bd[i + 3] = UInt8(Float(p[3]) * (1 - k)); cd[i + 3] = UInt8(Float(p[3]) * k)
}}
for (img, name) in [(bunny, "bunny.png"), (coins, "coins.png")] {
    try! img.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appending(path: name))
    print("wrote", name)
}
