import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture a mirrored notification may carry (PROTOCOL §5 `notification.img`).
///
/// Untrusted input: the size, the format and the pixel dimensions are checked before anything is
/// decoded, and the image is re-encoded from its pixels, so EXIF, GPS and anything appended after
/// the image data never reach the disk.
public enum NotificationImage {

    public static let maxBytes = 96 * 1024
    public static let maxBase64 = (maxBytes + 2) / 3 * 4
    /// The phone sends at most 512 px; anything past this is not ours and is not decoded.
    public static let maxEdge = 1024

    public enum Kind: String, Sendable { case picture, avatar }

    public struct Clean: Sendable, Equatable {
        public let data: Data
        public let fileExtension: String
        public let kind: Kind
    }

    /// The `img` / `img_kind` pair, validated and re-encoded, or nil.
    public static func sanitize(base64: Any?, kind: Any?) -> Clean? {
        guard let kind = (kind as? String).flatMap(Kind.init(rawValue:)),
              let text = base64 as? String, !text.isEmpty, text.utf8.count <= maxBase64,
              let data = Data(base64Encoded: text), data.count <= maxBytes,
              let type = signature(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == type.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maxEdge).contains(width), (1...maxEdge).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let out = alpha ? UTType.png : UTType.jpeg
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, out.identifier as CFString, 1, nil)
        else { return nil }
        let options = alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Clean(data: buffer as Data, fileExtension: alpha ? "png" : "jpg", kind: kind)
    }

    /// JPEG or PNG by magic bytes; everything else is refused before ImageIO sees it.
    static func signature(of data: Data) -> UTType? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        return nil
    }
}
