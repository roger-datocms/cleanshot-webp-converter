import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CleanShotWebPCore

func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "webp", subdirectory: "Fixtures")!
}

/// Builds a PNG-backed image source from a solid-colour bitmap, optionally with alpha and a custom DPI.
func makeImageSource(hasAlpha: Bool, dpi: Double = 72) -> CGImageSource {
    let context = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: hasAlpha ? 0.5 : 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, context.makeImage()!, properties)
    CGImageDestinationFinalize(destination)
    return CGImageSourceCreateWithData(data, nil)!
}

@Suite struct ImageConverterTests {
    @Test func photoBecomesJPEG() {
        let candidates = encodeSmallestFirst(fixtureURL("photo"))
        #expect(candidates.map(\.type) == [.jpeg, .png])
        #expect(candidates.first?.fileExtension == "jpg")
    }

    @Test func flatGraphicBecomesPNG() {
        let candidates = encodeSmallestFirst(fixtureURL("graphic"))
        #expect(candidates.map(\.type) == [.png, .jpeg])
        #expect(candidates.first?.fileExtension == "png")
    }

    @Test func transparentImageSkipsJPEG() {
        #expect(encodeCandidates(makeImageSource(hasAlpha: true)).map(\.type) == [.png])
    }

    @Test func opaqueImageTriesBoth() {
        #expect(encodeCandidates(makeImageSource(hasAlpha: false)).map(\.type) == [.png, .jpeg])
    }

    @Test func keepsRetinaDPI() throws {
        for image in encodeCandidates(makeImageSource(hasAlpha: false, dpi: 144)) {
            let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144, "\(image.fileExtension) lost its DPI")
        }
    }

    @Test func unreadableFileYieldsNoCandidates() {
        #expect(encodeSmallestFirst(URL(fileURLWithPath: "/nonexistent.webp")).isEmpty)
    }
}
