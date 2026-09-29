import AppKit

/// Returns the local path of the file URL on `pasteboard`, if any.
/// Checks the advertised types first, so unrelated clipboard contents (text, passwords) are never read.
public func fileURLPath(on pasteboard: NSPasteboard) -> String? {
    guard pasteboard.types?.contains(.fileURL) == true else { return nil }
    return pasteboard.string(forType: .fileURL).flatMap { URL(string: $0)?.standardizedFileURL.path }
}

/// Mirrors what CleanShot puts on the pasteboard: a file URL (when there's a file to point at) plus the raw image data.
public func writeImage(_ image: EncodedImage, at fileURL: URL?, to pasteboard: NSPasteboard) {
    let item = NSPasteboardItem()
    if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
    item.setData(image.data, forType: NSPasteboard.PasteboardType(image.type.identifier))
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}
