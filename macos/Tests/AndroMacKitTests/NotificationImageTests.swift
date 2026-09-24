import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AndroMacKit

struct NotificationImageTests {

    /// A solid image encoded as `type`, optionally with a GPS block to prove it is stripped.
    private func encoded(_ type: UTType, width: Int, height: Int, alpha: Bool = false, gps: Bool = false) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        let properties = gps ? [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 29.0, kCGImagePropertyGPSLongitudeRef: "E",
        ]] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func reencodesAJpegAndDropsItsMetadata() throws {
        let jpeg = try encoded(.jpeg, width: 64, height: 48, gps: true)
        #expect(try gpsOf(jpeg) != nil)            // the input really carries a location
        let clean = try #require(NotificationImage.sanitize(base64: jpeg.base64EncodedString(), kind: "picture"))
        #expect(clean.kind == .picture && clean.fileExtension == "jpg")
        #expect(try gpsOf(clean.data) == nil)
        let source = try #require(CGImageSourceCreateWithData(clean.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
    }

    private func gpsOf(_ data: Data) throws -> Any? {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return properties[kCGImagePropertyGPSDictionary]
    }

    @Test func keepsTransparencyAsPng() throws {
        let png = try encoded(.png, width: 32, height: 32, alpha: true)
        let clean = try #require(NotificationImage.sanitize(base64: png.base64EncodedString(), kind: "avatar"))
        #expect(clean.kind == .avatar && clean.fileExtension == "png")
        #expect(NotificationImage.signature(of: clean.data) == .png)
    }

    @Test func refusesWhatIsNotASmallJpegOrPng() throws {
        let jpeg = try encoded(.jpeg, width: 8, height: 8).base64EncodedString()
        #expect(NotificationImage.sanitize(base64: jpeg, kind: "sticker") == nil)
        #expect(NotificationImage.sanitize(base64: jpeg, kind: nil) == nil)
        #expect(NotificationImage.sanitize(base64: 42, kind: "picture") == nil)
        #expect(NotificationImage.sanitize(base64: "not base64!", kind: "picture") == nil)

        let gif = try encoded(.gif, width: 8, height: 8).base64EncodedString()
        #expect(NotificationImage.sanitize(base64: gif, kind: "picture") == nil)

        // A PNG signature in front of JPEG data: ImageIO's own sniffing must agree.
        var forged = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        forged.append(try encoded(.jpeg, width: 8, height: 8))
        #expect(NotificationImage.sanitize(base64: forged.base64EncodedString(), kind: "picture") == nil)

        // Over the pixel bound, however small the file.
        let huge = try encoded(.png, width: NotificationImage.maxEdge + 1, height: 1)
        #expect(huge.count < NotificationImage.maxBytes)
        #expect(NotificationImage.sanitize(base64: huge.base64EncodedString(), kind: "picture") == nil)

        // Over the byte cap: refused before it is decoded.
        var padded = try encoded(.jpeg, width: 8, height: 8)
        padded.append(Data(count: NotificationImage.maxBytes))
        #expect(NotificationImage.sanitize(base64: padded.base64EncodedString(), kind: "picture") == nil)
    }
}
