import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RemoteClipboardContent {
    typealias Wire = RemoteClipboardProtocol
    let format: Wire.Format
    let formats: UInt8
    let bytes: Data
    let digest: Data

    static func prepare(_ bytes: Data, format: Wire.Format, formats: UInt8,
                        fromWire: Bool) -> RemoteClipboardContent? {
        let canonical = format == .text ? Wire.canonicalText(bytes, fromWire: fromWire) : png(bytes, fromWire: fromWire)
        guard let canonical else { return nil }
        return Self(format: format, formats: formats, bytes: canonical, digest: Data(SHA256.hash(data: canonical)))
    }

    static func read(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var bytes = Data()
        do {
            while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - bytes.count)), !chunk.isEmpty {
                bytes.append(chunk)
                if bytes.count > limit { return nil }
            }
            return bytes
        } catch { return nil }
    }

    private static func allowedSize(width: Int, height: Int) -> Bool {
        (1...8192).contains(width) && (1...8192).contains(height) && width * height <= 16_777_216
    }

    /// Validate the PNG envelope before Image I/O allocates decoded pixels.
    private static func pngSize(_ bytes: Data, requireRGBA: Bool) -> (Int, Int)? {
        guard bytes.count >= 45, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        func be32(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
        }
        var offset = 8
        var width = 0, height = 0, hasData = false
        while offset <= bytes.count - 12 {
            let length = Int(be32(offset)), type = be32(offset + 4)
            guard length <= bytes.count - offset - 12 else { return nil }
            let checksumOffset = offset + 8 + length
            var crc: UInt32 = .max
            for byte in bytes[(offset + 4)..<checksumOffset] {
                crc = (crc >> 8) ^ pngCRC[Int((crc ^ UInt32(byte)) & 255)]
            }
            guard ~crc == be32(checksumOffset) else { return nil }
            if offset == 8 {
                guard type == 0x49484452, length == 13 else { return nil } // IHDR
                width = Int(be32(16)); height = Int(be32(20))
                guard allowedSize(width: width, height: height),
                      !requireRGBA || (bytes[24] == 8 && bytes[25] == 6) else { return nil }
            } else if type == 0x49484452 { return nil }
            switch type {
            case 0x6163544c, 0x6663544c, 0x66644154: return nil // acTL, fcTL, fdAT
            case 0x49444154: hasData = true // IDAT
            case 0x49454e44: // IEND
                return length == 0 && hasData && offset + 12 == bytes.count ? (width, height) : nil
            default: break
            }
            offset += length + 12
        }
        return nil
    }

    private static let pngCRC: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        return crc
    }

    private static func png(_ bytes: Data, fromWire: Bool) -> Data? {
        guard !bytes.isEmpty, bytes.count <= Wire.maxBytes else { return nil }
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        if fromWire || bytes.starts(with: pngSignature) {
            guard pngSize(bytes, requireRGBA: fromWire) != nil else { return nil }
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              allowedSize(width: width, height: height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: !fromWire,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              (image.width == width && image.height == height ||
               !fromWire && image.width == height && image.height == width),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        if fromWire { return bytes }

        guard let converted = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, converted, nil)
        let result = CGImageDestinationFinalize(encoder) && output.length <= Wire.maxBytes ? output as Data : nil
        guard let result, pngSize(result, requireRGBA: true) != nil else { return nil }
        return result
    }
}

/// One work item across providers and receive validation, with immediate backpressure.
final class RemoteClipboardContentWorker {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Remote clipboard content", qos: .utility)
    private var busy = false

    func submit(_ operation: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        queue.async {
            operation()
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
        }
        return true
    }
}
