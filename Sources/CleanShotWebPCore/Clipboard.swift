import AppKit

/// Returns the local path of the file URL on `pasteboard`, if any.
public func fileURLPath(on pasteboard: NSPasteboard) -> String? {
    pasteboard.string(forType: .fileURL).flatMap { URL(string: $0)?.standardizedFileURL.path }
}

/// Mirrors what CleanShot puts on the pasteboard: a file URL plus the raw image data.
public func writeImage(_ image: EncodedImage, at fileURL: URL, to pasteboard: NSPasteboard) {
    let item = NSPasteboardItem()
    item.setString(fileURL.absoluteString, forType: .fileURL)
    item.setData(image.data, forType: NSPasteboard.PasteboardType(image.type.identifier))
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}
