import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// Usage: layers <source.png> <out dir>
let args = CommandLine.arguments
let src = CIImage(contentsOf: URL(fileURLWithPath: args[1]))!
let out = URL(fileURLWithPath: args[2])
let ctx = CIContext()
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Art inside the baked squircle rim: 960 px square centered on the icon, scaled to the 1024 canvas.
let side: CGFloat = 960, cx: CGFloat = 626, cyTop: CGFloat = 617
let H = src.extent.height
let crop = CGRect(x: cx - side / 2, y: H - cyTop - side / 2, width: side, height: side)
let art = src.cropped(to: crop)
    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    .transformed(by: CGAffineTransform(scaleX: 1024 / side, y: 1024 / side))
    .cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let artCG = ctx.createCGImage(art, from: art.extent, format: .RGBA8, colorSpace: srgb)!

func save(_ image: CIImage, _ name: String) {
    try! ctx.writePNGRepresentation(of: image.cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024)),
                                    to: out.appending(path: name), format: .RGBA8, colorSpace: srgb)
    print("wrote", name)
}

// Subject segmentation: bunny and coin stack.
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: artCG)
try handler.perform([request])
guard let obs = request.results?.first else { fatalError("no subject found") }
print("instances:", Array(obs.allInstances))
func mask(_ set: IndexSet) -> CIImage {
    let buf = try! obs.generateScaledMaskForImage(forInstances: set, from: handler)
    return CIImage(cvPixelBuffer: buf)
}
let artImage = CIImage(cgImage: artCG)
let clear = CIImage(color: .clear).cropped(to: artImage.extent)
func cutout(_ m: CIImage) -> CIImage {
    let f = CIFilter.blendWithMask(); f.inputImage = artImage; f.backgroundImage = clear; f.maskImage = m
    return f.outputImage!
}

// Name instances left→right: the bunny sits left of the coins.
func centroidX(_ m: CIImage) -> CGFloat {
    let cg = ctx.createCGImage(m, from: m.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
    let rep = NSBitmapImageRep(cgImage: cg)
    var sum = 0.0, wsum = 0.0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 4) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
        let v = Double(rep.bitmapData![y * rep.bytesPerRow + x]); sum += v * Double(x); wsum += v } }
    return wsum > 0 ? sum / wsum : 0
}
let instances = obs.allInstances.map { ($0, mask(IndexSet(integer: $0))) }.sorted { centroidX($0.1) < centroidX($1.1) }
let all = mask(obs.allInstances)
if instances.count >= 2 {
    save(cutout(instances[0].1), "bunny.png")
    save(cutout(mask(IndexSet(instances.dropFirst().map(\.0)))), "coins.png")
} else {
    save(cutout(all), "subject.png")
}
save(all, "mask.png")

// Background: fill under the subject from its surroundings (push-pull of premultiplied blurs).
let dilated = all.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 10]).cropped(to: artImage.extent)
let inverse = dilated.applyingFilter("CIColorInvert")
let known = { let f = CIFilter.blendWithMask(); f.inputImage = artImage; f.backgroundImage = clear; f.maskImage = inverse; return f.outputImage! }()
func blur(_ r: Double) -> CIImage { known.clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: artImage.extent) }
var fill = blur(140).applyingFilter("CIUnpremultiply")
for r in [90.0, 50, 25, 12] { fill = blur(r).composited(over: fill) }
let background = known.composited(over: fill).cropped(to: artImage.extent)
save(background, "background.png")
let dark = background
    .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -0.9])
    .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.95, "inputContrast": 1.05])
save(dark, "background-dark.png")
save(artImage, "art.png")
