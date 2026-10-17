import AppKit
import Observation
import OpenDirectory
import UniformTypeIdentifiers

/// The person behind the toolbar avatar: their macOS account picture, or a photo they chose.
@MainActor
@Observable
final class ProfileModel {
    private(set) var photo: NSImage?
    private(set) var hasCustomPhoto = false
    let name = NSFullUserName()

    @ObservationIgnored private let customPhotoURL: URL

    init(directory: URL) {
        customPhotoURL = directory.appending(path: "profile-photo.png")
        load()
    }

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    private func load() {
        if let image = NSImage(contentsOf: customPhotoURL) {
            photo = image
            hasCustomPhoto = true
            return
        }
        hasCustomPhoto = false
        photo = nil
        Task {
            let data = await Task.detached(priority: .utility) { Self.accountPictureData() }.value
            if !hasCustomPhoto, let data { photo = NSImage(data: data) }
        }
    }

    /// The login picture from the local directory (what System Settings › Users shows).
    nonisolated private static func accountPictureData() -> Data? {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                            attributes: [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture]) else { return nil }
        if let data = (try? record.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data, !data.isEmpty {
            return data
        }
        if let path = (try? record.values(forAttribute: kODAttributeTypePicture))?.first as? String {
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return nil
    }

    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a profile photo"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let png = Self.squarePNG(image, side: 256) else { return }
        try? FileManager.default.createDirectory(at: customPhotoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: customPhotoURL, options: .atomic)
        load()
    }

    func useAccountPicture() {
        try? FileManager.default.removeItem(at: customPhotoURL)
        load()
    }

    /// Center-crops to a square and scales down, so the stored photo stays small.
    private static func squarePNG(_ image: NSImage, side: Int) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let crop = min(cg.width, cg.height)
        guard let square = cg.cropping(to: CGRect(x: (cg.width - crop) / 2, y: (cg.height - crop) / 2, width: crop, height: crop)),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
