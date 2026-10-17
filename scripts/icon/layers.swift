import AppKit
import CoreImage
import Vision

// Usage: layers <source.png> <out dir>
// Cuts the white bunny line art out of the flat artwork (scripts/icon/source.png, 1254 px with a baked squircle)
// into white-on-transparent 1024 layers: outline.png (head, ears, nose, smile) and eye.png.
// Colour finds the white and lavender parts of the stroke; where the tube is shaded violet (the bottom of the head),
// the outer edge comes from Vision's subject mask instead, as a band just inside its silhouette.
// Colour, glass, rim, specular highlights and shadows come from icon.json and the system, so the PNGs carry only shape.
let args = CommandLine.arguments
let img = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = URL(fileURLWithPath: args[2])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let gray = CGColorSpaceCreateDeviceGray()
let W = img.width, H = img.height
let src = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: srgb,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
src.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
let px = src.data!.assumingMemoryBound(to: UInt8.self)   // row 0 = top

// The line art is white to lavender: blue stays near full while green stays well above the pinks.
// The pale rim glow has a weaker blue, and the violet glow under the head a low green.
let art = (x: 214..<1100, y: 150..<1080)
func level(_ i: Int) -> UInt8 { art.x.contains(i % W) && art.y.contains(i / W) && px[i * 4 + 1] >= 150 ? px[i * 4 + 2] : 0 }
// Hysteresis: a piece starts on clearly white pixels and grows through the lavender-shaded parts of the stroke.
let strong: UInt8 = 242, weak: UInt8 = 214

// Connected pieces of the line art.
var label = [Int32](repeating: 0, count: W * H)
struct Piece { var id: Int32; var area = 0; var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0 }
var pieces: [Piece] = []
var nextID: Int32 = 0
for start in 0..<(W * H) where label[start] == 0 && level(start) >= strong {
    nextID += 1
    var c = Piece(id: nextID)
    var stack = [start]; label[start] = c.id
    while let i = stack.popLast() {
        let x = i % W, y = i / W
        c.area += 1; c.minX = min(c.minX, x); c.maxX = max(c.maxX, x); c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
        for j in [i - 1, i + 1, i - W, i + W] where j >= 0 && j < W * H && label[j] == 0 && level(j) >= weak {
            label[j] = c.id; stack.append(j)
        }
    }
    // Pieces cut by the art window are rim glow, not line art.
    let edge = c.minX == art.x.lowerBound || c.maxX == art.x.upperBound - 1 || c.minY == art.y.lowerBound || c.maxY == art.y.upperBound - 1
    if c.area > 500 && !edge { pieces.append(c) }
}
// The eye is the closed arc in the middle of the head; everything else large belongs to the outline.
let eye = pieces.filter { $0.minX > 700 && $0.maxX < 950 && $0.minY > 680 && $0.maxY < 850 }
let outline = pieces.filter { p in !eye.contains { $0.id == p.id } }
for p in pieces { print(eye.contains { $0.id == p.id } ? "eye" : "outline", p.area, p.minX...p.maxX, p.minY...p.maxY) }

// Squircle of the artwork (outer edge of the baked rim) maps onto the 1024 canvas.
let squircle = CGRect(x: 78, y: 66, width: 1101, height: 1101)
let S = 1024
let ci = CIContext()
let full = CGRect(x: 0, y: 0, width: W, height: H)

func maskImage(_ parts: [Piece]) -> CIImage {
    let ids = Set(parts.map(\.id))
    return grayImage(label.map { ids.contains($0) ? 255 : 0 })
}

// Vision subject mask, run inside the squircle (or the whole tile is the subject): right silhouette, noisy inside.
// Fill it solid and keep a band just inside the silhouette, narrower than the stroke.
let inside = img.cropping(to: squircle)!
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: inside)
try handler.perform([request])
let observation = request.results!.first!
let subjectCI = CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler))
    .transformed(by: CGAffineTransform(translationX: squircle.minX, y: CGFloat(H) - squircle.maxY))
    .composited(over: CIImage(color: .black).cropped(to: full))
var subject = [UInt8](repeating: 0, count: W * H)
ci.render(subjectCI, toBitmap: &subject, rowBytes: W, bounds: full, format: .L8, colorSpace: nil)   // row 0 = top
var outside = [Bool](repeating: false, count: W * H)
var stack = [0]; outside[0] = true
while let i = stack.popLast() {
    for j in [i - 1, i + 1, i - W, i + W] where j >= 0 && j < W * H && !outside[j] && subject[j] < 128 { outside[j] = true; stack.append(j) }
}
let solidSubject = outside.map { $0 ? UInt8(0) : 255 }
func grayImage(_ bytes: [UInt8]) -> CIImage {
    CIImage(cgImage: CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W, space: gray,
                             bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                             decode: nil, shouldInterpolate: false, intent: .defaultIntent)!)
}
// The right ear is open at its base, so the fill only holds for the lower head, which is also the only place
// the stroke turns violet: the band is limited to that window (image coordinates, top-left origin).
let lowerHead = { (x: Int, y: Int) in (x < 660 && y >= 560) || (x <= 940 && y >= 780) }
let filled = grayImage(solidSubject.indices.map { solidSubject[$0] > 0 && lowerHead($0 % W, $0 / W) ? 255 : 0 })
let solid = grayImage(solidSubject)
let core = solid.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 60]).cropped(to: full)
let band = core.applyingFilter("CIColorInvert").applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": filled])

func layer(_ mask: CIImage, _ name: String) {
    // Close the shading gaps inside the stroke, scale onto the canvas, then soften and re-sharpen for a clean edge.
    let k = CGFloat(S) / squircle.width
    let canvas = CGRect(x: 0, y: 0, width: S, height: S)
    let alpha = mask.clampedToExtent()
        .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 4])
        .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 4])
        .transformed(by: CGAffineTransform(translationX: -squircle.minX, y: -(CGFloat(H) - squircle.maxY)).concatenating(CGAffineTransform(scaleX: k, y: k)))
        .applyingGaussianBlur(sigma: 2.2)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2.6, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: -0.8, y: 0, z: 0, w: 0)])
        .applyingFilter("CIColorClamp")
        .cropped(to: canvas)
    let white = CIImage(color: .white).cropped(to: canvas)
    let clear = CIImage(color: .clear).cropped(to: canvas)
    let result = white.applyingFilter("CIBlendWithRedMask", parameters: ["inputBackgroundImage": clear, "inputMaskImage": alpha])
    try! ci.writePNGRepresentation(of: result, to: out.appending(path: name), format: .RGBA8, colorSpace: srgb)
    print("wrote", name)
}
layer(maskImage(outline).applyingFilter("CIMaximumCompositing", parameters: ["inputBackgroundImage": band]), "outline.png")
layer(maskImage(eye), "eye.png")
