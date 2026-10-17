// dmgtool: helpers for scripts/make-dmg.sh, built with swiftc (no third-party code).
//
//   dmgtool background <icon.png> <out-dir> <width> <height> <app-x> <apps-x> <icon-y>
//       Draws background.png (1x) and background@2x.png: a light sheet with a faint grid, the BunnyGrid
//       icon and wordmark, and an arrow from the app's slot to the Applications slot.
//   dmgtool dsstore <mounted volume> <volume name> <background path in volume> <width> <height> <icon size>
//       <name>=<x>,<y> ...
//       Writes <volume>/.DS_Store with the Finder window layout: window size, no toolbar/sidebar, icon view,
//       icon size, background picture and each item's position.
//
// The .DS_Store is a "Bud1" buddy-allocated B-tree (one leaf node here). The window settings are binary plists
// ('bwsp', 'icvp'); the background picture is referenced by a classic Alias (version 2) record, which Finder
// resolves by volume name + path, so it keeps working wherever the DMG is mounted.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Background artwork

func drawBackground(iconPath: String, outDir: String, width: Int, height: Int, appX: Int, appsX: Int, iconY: Int) throws {
    let icon = NSImage(contentsOfFile: iconPath)
    for scale in [1, 2] {
        let w = width * scale, h = height * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Fail("no context") }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Flip so y grows downwards, like Finder's icon coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let W = CGFloat(width), H = CGFloat(height)

        // Warm off-white sheet with a soft rose glow (the icon's red, very diluted).
        let sheet = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 1.0, green: 0.985, blue: 0.98, alpha: 1),
            CGColor(srgbRed: 0.985, green: 0.95, blue: 0.945, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheet, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0.86, green: 0.16, blue: 0.18, alpha: 0.10),
            CGColor(srgbRed: 0.86, green: 0.16, blue: 0.18, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.5, y: CGFloat(iconY)), startRadius: 0,
                               endCenter: CGPoint(x: W * 0.5, y: CGFloat(iconY)), endRadius: W * 0.55, options: [])

        // The grid: hairlines every 24 pt, fading out towards the bottom.
        ctx.saveGState()
        ctx.setLineWidth(1 / CGFloat(scale))
        let step: CGFloat = 24
        var x: CGFloat = step
        while x < W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += step }
        var y: CGFloat = step
        while y < H { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += step }
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0.55, green: 0.12, blue: 0.14, alpha: 0.10),
            CGColor(srgbRed: 0.55, green: 0.12, blue: 0.14, alpha: 0.02),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fade, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        ctx.restoreGState()

        // Arrow from the app slot to the Applications slot: a gentle arc with a rounded head.
        let from = CGPoint(x: CGFloat(appX) + 78, y: CGFloat(iconY))
        let to = CGPoint(x: CGFloat(appsX) - 78, y: CGFloat(iconY))
        let control = CGPoint(x: (from.x + to.x) / 2, y: CGFloat(iconY) - 34)
        ctx.setStrokeColor(CGColor(srgbRed: 0.80, green: 0.13, blue: 0.16, alpha: 0.85))
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [0.1, 11])
        ctx.move(to: from)
        ctx.addQuadCurve(to: to, control: control)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        // Head, along the curve's end tangent.
        let angle = atan2(to.y - control.y, to.x - control.x)
        let size: CGFloat = 13
        let left = CGPoint(x: to.x - size * cos(angle - .pi / 5), y: to.y - size * sin(angle - .pi / 5))
        let right = CGPoint(x: to.x - size * cos(angle + .pi / 5), y: to.y - size * sin(angle + .pi / 5))
        ctx.move(to: left); ctx.addLine(to: to); ctx.addLine(to: right)
        ctx.strokePath()

        // Brand row and caption, drawn with AppKit text in the flipped context.
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        if let icon {
            icon.draw(in: NSRect(x: 22, y: 18, width: 34, height: 34), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        let title = NSAttributedString(string: "BunnyGrid", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.18, green: 0.10, blue: 0.11, alpha: 1),
        ])
        title.draw(at: NSPoint(x: 64, y: 24))
        let caption = NSAttributedString(string: "Drag BunnyGrid to Applications to install", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.35, green: 0.25, blue: 0.26, alpha: 1),
        ])
        let size2 = caption.size()
        caption.draw(at: NSPoint(x: (W - size2.width) / 2, y: CGFloat(iconY) + 108))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { throw Fail("no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: width, height: height)  // 144 dpi for @2x
        let name = scale == 1 ? "background.png" : "background@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appending(path: name))
    }
}

// MARK: - Alias record (version 2)

/// Seconds between 1904-01-01 (HFS epoch) and 1970-01-01.
let hfsEpochOffset: TimeInterval = 2_082_844_800

func hfsDate(_ date: Date) -> UInt32 { UInt32(clamping: Int64(date.timeIntervalSince1970 + hfsEpochOffset)) }

struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    /// Pascal string in a fixed-size field.
    mutating func pascal(_ s: String, field: Int) {
        let raw = Array(s.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(field - 1)
        u8(UInt8(raw.count)); data.append(contentsOf: raw)
        data.append(contentsOf: [UInt8](repeating: 0, count: field - 1 - raw.count))
    }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
}

func inode(_ path: String) throws -> UInt32 {
    var st = stat()
    guard stat(path, &st) == 0 else { throw Fail("stat \(path)") }
    return UInt32(truncatingIfNeeded: st.st_ino)
}

/// Alias to `relativePath` (e.g. ".background/background.png") on the volume mounted at `mount`, recorded as if
/// the volume were at /Volumes/<volumeName> (where users will mount it).
func aliasRecord(mount: String, volumeName: String, relativePath: String) throws -> Data {
    let fileURL = URL(fileURLWithPath: mount).appending(path: relativePath)
    let parentURL = fileURL.deletingLastPathComponent()
    let values = try URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeCreationDateKey])
    let volumeDate = values.volumeCreationDate ?? Date()
    let fileDate = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let fileName = fileURL.lastPathComponent
    let parentName = parentURL.lastPathComponent
    let fileID = try inode(fileURL.path), parentID = try inode(parentURL.path)

    var w = Writer()
    w.u32(0)                          // application info
    w.u16(0)                          // record size, patched below
    w.u16(2)                          // version
    w.u16(0)                          // kind: file
    w.pascal(volumeName, field: 28)
    w.u32(hfsDate(volumeDate))
    w.ascii("H+")                     // file system
    w.u16(5)                          // disk type: other ejectable media
    w.u32(parentID)
    w.pascal(fileName, field: 64)
    w.u32(fileID)
    w.u32(hfsDate(fileDate))
    w.zeros(8)                        // creator, type
    w.i16(-1); w.i16(-1)              // nlvl from, to
    w.u32(0)                          // volume attributes
    w.u16(0)                          // volume file system id
    w.zeros(10)
    func tag(_ t: Int16, _ d: Data) {
        w.i16(t); w.u16(UInt16(d.count)); w.bytes(d)
        if d.count % 2 == 1 { w.u8(0) }
    }
    func utf16(_ s: String) -> Data {
        var d = Writer(); d.u16(UInt16(s.utf16.count)); for c in s.utf16 { d.u16(c) }; return d.data
    }
    tag(0, parentName.data(using: .macOSRoman, allowLossyConversion: true) ?? Data())
    var cnids = Writer(); cnids.u32(parentID); tag(1, cnids.data)
    let carbon = ([volumeName] + relativePath.split(separator: "/").map(String.init)).joined(separator: ":")
    tag(2, carbon.data(using: .macOSRoman, allowLossyConversion: true) ?? Data())
    tag(14, utf16(fileName))
    tag(15, utf16(volumeName))
    tag(18, Data(("/" + relativePath).utf8))
    tag(19, Data(("/Volumes/" + volumeName).utf8))
    w.i16(-1); w.u16(0)
    var data = w.data
    let size = UInt16(data.count).bigEndian
    withUnsafeBytes(of: size) { data.replaceSubrange(4..<6, with: $0) }
    return data
}

// MARK: - .DS_Store

enum Value {
    case blob(Data), long(UInt32), bool(Bool)
}

struct Record {
    let name: String
    let code: String
    let value: Value

    func encode(into w: inout Writer) {
        w.u32(UInt32(name.utf16.count)); for c in name.utf16 { w.u16(c) }
        w.ascii(code)
        switch value {
        case .blob(let d): w.ascii("blob"); w.u32(UInt32(d.count)); w.bytes(d)
        case .long(let v): w.ascii("long"); w.u32(v)
        case .bool(let v): w.ascii("bool"); w.u8(v ? 1 : 0)
        }
    }
}

func plist(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

func writeDSStore(mount: String, volumeName: String, background: String, width: Int, height: Int, iconSize: Int,
                  positions: [(String, Int, Int)]) throws {
    let alias = try aliasRecord(mount: mount, volumeName: volumeName, relativePath: background)
    let bwsp = try plist([
        // The bounds are the whole window: add the title bar so the picture fits the content area.
        "WindowBounds": "{{200, 120}, {\(width), \(height + 28)}}",
        "ShowToolbar": false, "ShowSidebar": false, "ShowStatusBar": false, "ShowPathbar": false,
        "ShowTabView": false, "ContainerShowSidebar": false, "SidebarWidth": 0, "PreviewPaneVisibility": false,
    ])
    let icvp = try plist([
        "viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": Double(iconSize), "textSize": 13.0,
        "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0, "labelOnBottom": true,
        "showIconPreview": true, "showItemInfo": false,
        "backgroundType": 2, "backgroundImageAlias": alias,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
    ])
    var records = [
        Record(name: ".", code: "bwsp", value: .blob(bwsp)),
        Record(name: ".", code: "icvp", value: .blob(icvp)),
        Record(name: ".", code: "vSrn", value: .long(1)),
    ]
    for (name, x, y) in positions {
        var w = Writer(); w.u32(UInt32(x)); w.u32(UInt32(y)); w.bytes(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]))
        records.append(Record(name: name, code: "Iloc", value: .blob(w.data)))
    }
    // Finder keeps records sorted by name (case-insensitive), then by code.
    records.sort {
        let order = $0.name.compare($1.name, options: [.caseInsensitive])
        return order == .orderedSame ? $0.code < $1.code : order == .orderedAscending
    }

    // Leaf node: P = 0 (no children), count, records.
    var leaf = Writer(); leaf.u32(0); leaf.u32(UInt32(records.count))
    for r in records { r.encode(into: &leaf) }
    var leafLog = 12
    while (1 << leafLog) < leaf.data.count { leafLog += 1 }

    // Block layout in the buddy allocator's address space (offsets are relative to file byte 4):
    //   [0, 32) header, [32, 64) DSDB (block 1), [2048, 4096) allocator info (block 0), leaf (block 2) after it.
    let infoAddr = 2048, infoLog = 11
    let dsdbAddr = 32, dsdbLog = 5
    let leafAddr = max(4096, 1 << leafLog)
    let used = [(0, 5), (dsdbAddr, dsdbLog), (infoAddr, infoLog), (leafAddr, leafLog)]

    var dsdb = Writer()
    dsdb.u32(2)                // root node block id
    dsdb.u32(0)                // internal levels
    dsdb.u32(UInt32(records.count))
    dsdb.u32(1)                // nodes
    dsdb.u32(0x1000)           // page size

    // Free lists: split the 2^31 address space; every untouched buddy is free at its size.
    var free = [[UInt32]](repeating: [], count: 32)
    func split(_ addr: Int, _ log: Int) {
        let end = addr + (1 << log)
        let inside = used.filter { $0.0 >= addr && $0.0 < end }
        if inside.isEmpty { free[log].append(UInt32(addr)); return }
        if inside.count == 1, inside[0].0 == addr, inside[0].1 == log { return }
        split(addr, log - 1); split(addr + (1 << (log - 1)), log - 1)
    }
    split(0, 31)

    var info = Writer()
    let offsets: [UInt32] = [UInt32(infoAddr | infoLog), UInt32(dsdbAddr | dsdbLog), UInt32(leafAddr | leafLog)]
    info.u32(UInt32(offsets.count)); info.u32(0)
    for o in offsets { info.u32(o) }
    info.zeros(4 * (256 - offsets.count))
    info.u32(1); info.u8(4); info.ascii("DSDB"); info.u32(1)
    for list in free { info.u32(UInt32(list.count)); for a in list { info.u32(a) } }
    guard info.data.count <= 1 << infoLog else { throw Fail("allocator info too large") }

    var file = Data(count: 4 + leafAddr + (1 << leafLog))
    func put(_ d: Data, at addr: Int) { file.replaceSubrange(4 + addr ..< 4 + addr + d.count, with: d) }
    var header = Writer()
    header.u32(1); header.ascii("Bud1")
    header.u32(UInt32(infoAddr)); header.u32(UInt32(1 << infoLog)); header.u32(UInt32(infoAddr))
    header.zeros(16)
    file.replaceSubrange(0..<header.data.count, with: header.data)
    put(dsdb.data, at: dsdbAddr)
    put(info.data, at: infoAddr)
    put(leaf.data, at: leafAddr)
    try file.write(to: URL(fileURLWithPath: mount).appending(path: ".DS_Store"))
}

// MARK: - Main

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "background" where args.count == 8:
        try drawBackground(iconPath: args[1], outDir: args[2], width: Int(args[3])!, height: Int(args[4])!,
                           appX: Int(args[5])!, appsX: Int(args[6])!, iconY: Int(args[7])!)
    case "dsstore" where args.count >= 7:
        let positions = try args.dropFirst(7).map { item -> (String, Int, Int) in
            guard let eq = item.lastIndex(of: "=") else { throw Fail("bad position \(item)") }
            let xy = item[item.index(after: eq)...].split(separator: ",").compactMap { Int($0) }
            guard xy.count == 2 else { throw Fail("bad position \(item)") }
            return (String(item[..<eq]), xy[0], xy[1])
        }
        try writeDSStore(mount: args[1], volumeName: args[2], background: args[3], width: Int(args[4])!,
                         height: Int(args[5])!, iconSize: Int(args[6])!, positions: positions)
    default:
        FileHandle.standardError.write(Data("usage: dmgtool background|dsstore …\n".utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("dmgtool: \(error)\n".utf8))
    exit(1)
}
