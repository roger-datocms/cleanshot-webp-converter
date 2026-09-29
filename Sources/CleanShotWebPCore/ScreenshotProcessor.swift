import AppKit

/// Outcome of processing one WebP file, for logging and tests.
public enum ProcessingResult: Equatable, Sendable {
    case notNew
    case notOnClipboard
    case encodingFailed
    /// Converted and saved, but the clipboard moved on to something else meanwhile.
    case savedOnly(URL)
    case savedAndCopied(URL)
}

/// Timing knobs, overridable in tests.
public struct ProcessingTiming: Sendable {
    public var clipboardTimeout: TimeInterval = 5
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

/// Waits until the file size stops changing. Returns `false` if the file is gone or not freshly created.
func waitForNewStableFile(_ url: URL, timing: ProcessingTiming) -> Bool {
    var previousSize = -1
    while true {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let created = attributes[.creationDate] as? Date,
              Date().timeIntervalSince(created) < timing.maxFileAge,
              let size = attributes[.size] as? Int
        else { return false }
        if size > 0 && size == previousSize { return true }
        previousSize = size
        Thread.sleep(forTimeInterval: timing.pollInterval)
    }
}

/// Converts a freshly captured WebP that CleanShot also copied to `pasteboard`.
/// Saves the smaller of PNG/JPEG next to it and points the clipboard at that copy.
public func processScreenshot(
    at url: URL,
    pasteboard: NSPasteboard,
    jpegQuality: Double = 0.85,
    timing: ProcessingTiming = ProcessingTiming()
) throws -> (result: ProcessingResult, candidates: [EncodedImage]) {
    let path = url.standardizedFileURL.path
    guard waitForNewStableFile(url, timing: timing) else { return (.notNew, []) }
    guard poll(timeout: timing.clipboardTimeout, interval: timing.pollInterval, { fileURLPath(on: pasteboard) == path }) else {
        return (.notOnClipboard, [])
    }

    let candidates = encodeSmallestFirst(url, jpegQuality: jpegQuality)
    guard let smallest = candidates.first else { return (.encodingFailed, []) }
    let outputURL = url.deletingPathExtension().appendingPathExtension(smallest.fileExtension)
    try smallest.data.write(to: outputURL)

    // CleanShot may have moved on to a newer capture while we were encoding.
    guard fileURLPath(on: pasteboard) == path else { return (.savedOnly(outputURL), candidates) }
    writeImage(smallest, at: outputURL, to: pasteboard)
    return (.savedAndCopied(outputURL), candidates)
}
