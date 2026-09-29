import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One re-encoded version of a screenshot.
public struct EncodedImage: Sendable {
    public let type: UTType
    public let data: Data

    public var fileExtension: String { type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "img" }
    public var formatName: String { type == .jpeg ? "JPEG" : fileExtension.uppercased() }
}

/// One-line summary for the toast, e.g. "Converted shot.webp (142 KB) to JPEG (51 KB)".
public func conversionSummary(sourceName: String, sourceSize: Int, result: EncodedImage) -> String {
    let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    return "Converted \(sourceName) (\(format(sourceSize))) to \(result.formatName) (\(format(result.data.count)))"
}

/// Re-encodes the first image of `source`, keeping its metadata (notably the Retina DPI).
func encode(_ source: CGImageSource, as type: UTType, options: [CFString: Any] = [:]) -> EncodedImage? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
    return CGImageDestinationFinalize(destination) ? EncodedImage(type: type, data: data as Data) : nil
}

/// Whether the image has an alpha channel. JPEG would flatten it (e.g. CleanShot window shadows).
func hasAlpha(_ source: CGImageSource) -> Bool {
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    return ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
}

/// Encodes `source` as PNG and, when it's opaque, as JPEG. Returns every successful candidate.
public func encodeCandidates(_ source: CGImageSource, jpegQuality: Double = 0.85) -> [EncodedImage] {
    let png = encode(source, as: .png)
    let jpeg = hasAlpha(source)
        ? nil
        : encode(source, as: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: jpegQuality])
    return [png, jpeg].compactMap { $0 }
}

/// Encodes the image at `url` into each candidate format and returns them with the smallest first.
public func encodeSmallestFirst(_ url: URL, jpegQuality: Double = 0.85) -> [EncodedImage] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
    return encodeCandidates(source, jpegQuality: jpegQuality).sorted { $0.data.count < $1.data.count }
}
