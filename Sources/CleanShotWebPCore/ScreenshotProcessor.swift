import AppKit

/// Outcome of processing one WebP file, for logging and tests.
public enum ProcessingResult: Equatable, Sendable {
    /// The file is gone, or wasn't written recently (neither a new capture nor a fresh edit).
    case notRecent
    case notOnClipboard
    case encodingFailed
    /// Converted and saved, but the clipboard moved on to something else meanwhile.
    case savedOnly(URL)
    case savedAndCopied(URL)
}

/// Timing knobs, overridable in tests.
public struct ProcessingTiming: Sendable {
    public var clipboardTimeout: TimeInterval = 5
    /// How recently the file must have been written (captured or re-saved after an edit).
    public var maxFileAge: TimeInterval = 30
    public var pollInterval: TimeInterval = 0.25

    public init() {}
}

/// Polls until `check` passes or `timeout` elapses.
func poll(timeout: TimeInterval, interval: TimeInterval, _ check: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if check() { return true }
        Thread.sleep(forTimeInterval: interval)
    } while Date() < deadline
    return false
}

/// Identifies one saved version of a file, so each capture or edit is converted once.
public struct FileVersion: Equatable, Sendable {
    public let modified: Date
    public let size: Int

    public init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        self.modified = modified
        self.size = size
    }
}

/// Waits until the file size stops changing. Returns `false` if the file is gone or wasn't written recently.
/// Uses the modification date, because CleanShot re-saves edited captures in place.
func waitForRecentStableFile(_ url: URL, timing: ProcessingTiming) -> Bool {
    var previousSize = -1
    while true {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < timing.maxFileAge,
              let size = attributes[.size] as? Int
        else { return false }
        if size > 0 && size == previousSize { return true }
        previousSize = size
        Thread.sleep(forTimeInterval: timing.pollInterval)
    }
}

/// Converts a freshly captured or edited WebP that CleanShot also copied to `pasteboard`.
/// Saves the smaller of PNG/JPEG next to it (replacing an earlier conversion) and points the clipboard at that copy.
public func processScreenshot(
    at url: URL,
    pasteboard: NSPasteboard,
    jpegQuality: Double = 0.85,
    timing: ProcessingTiming = ProcessingTiming()
) throws -> (result: ProcessingResult, candidates: [EncodedImage]) {
    let path = url.standardizedFileURL.path
    guard waitForRecentStableFile(url, timing: timing) else { return (.notRecent, []) }
    guard poll(timeout: timing.clipboardTimeout, interval: timing.pollInterval, { fileURLPath(on: pasteboard) == path }) else {
        return (.notOnClipboard, [])
    }

    let candidates = encodeSmallestFirst(url, jpegQuality: jpegQuality)
    guard let smallest = candidates.first else { return (.encodingFailed, []) }
    let outputURL = url.deletingPathExtension().appendingPathExtension(smallest.fileExtension)
    try smallest.data.write(to: outputURL, options: .atomic)
    removeStaleConversions(of: url, keeping: outputURL)

    // CleanShot may have moved on to a newer capture while we were encoding.
    guard fileURLPath(on: pasteboard) == path else { return (.savedOnly(outputURL), candidates) }
    writeImage(smallest, at: outputURL, to: pasteboard)
    return (.savedAndCopied(outputURL), candidates)
}

/// Deletes an earlier conversion in another format, e.g. the PNG made before an edit tipped the result to JPEG.
/// Only siblings created after the WebP itself count, so an unrelated older file with the same name survives.
func removeStaleConversions(of url: URL, keeping outputURL: URL) {
    let fileManager = FileManager.default
    guard let sourceCreated = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date else { return }
    for fileExtension in ["png", "jpg"] {
        let sibling = url.deletingPathExtension().appendingPathExtension(fileExtension)
        guard sibling != outputURL,
              let created = (try? fileManager.attributesOfItem(atPath: sibling.path))?[.creationDate] as? Date,
              created >= sourceCreated
        else { continue }
        try? fileManager.removeItem(at: sibling)
    }
}
