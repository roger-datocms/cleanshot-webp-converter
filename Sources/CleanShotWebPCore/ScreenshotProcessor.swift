import AppKit

/// Outcome of handling one CleanShot WebP, from either trigger, for logging and tests.
public enum ProcessingResult: Equatable, Sendable {
    /// The file never appeared (e.g. CleanShot's "Save" action is off).
    case fileMissing
    /// Something else was copied while we were working, so the clipboard was left alone.
    case clipboardChanged
    case encodingFailed
    /// A fresh capture or edit: the conversion was saved next to the WebP and copied.
    case savedAndCopied(URL)
    /// An older capture re-copied (e.g. from CleanShot's history) whose up-to-date conversion already exists.
    case copiedExisting(URL)
    /// An older capture re-copied with no conversion on disk: only the clipboard got the converted image.
    case copiedDataOnly
    /// Saved but not copied (CleanShot's "Copy" action is off): the conversion was saved, the clipboard left alone.
    case savedOnly(URL)
    /// A saved file that CleanShot also copied, so the clipboard trigger converts it instead.
    case leftToClipboard
    /// This exact version was already converted by the other trigger.
    case alreadyConverted
    /// A file event for something not saved recently (e.g. a rename or a touch), so not a new capture or edit.
    case notFresh
}

/// Timing knobs, overridable in tests.
public struct ProcessingTiming: Sendable {
    /// How long to wait for the copied file to appear and finish writing.
    public var fileTimeout: TimeInterval = 5
    /// Files saved more recently than this count as a fresh capture or edit and get a converted copy on disk.
    public var freshSaveAge: TimeInterval = 30
    /// How long a freshly saved file waits for CleanShot to also copy it, before being treated as save-only.
    public var copyGrace: TimeInterval = 1.5
    public var pollInterval: TimeInterval = 0.25

    public init() {}
}

/// Identifies one saved version of a file, so the two triggers never convert the same capture or edit twice.
public struct FileVersion: Equatable, Sendable {
    public let modified: Date
    public let size: Int

    public init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        self.init(attributes)
    }

    init?(_ attributes: [FileAttributeKey: Any]) {
        guard let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else { return nil }
        self.modified = modified
        self.size = size
    }
}

/// CleanShot's history storage: one `media_*` folder per capture, each holding a copy named like the original.
public let cleanShotMediaDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/CleanShot/media", isDirectory: true)

/// Whether `url` is a WebP that CleanShot produced: in its export folder or its history storage, named by its template.
/// The clipboard doesn't record which app copied a file, so location and name are the reliable signals.
public func isCleanShotWebP(_ url: URL, settings: CleanShotSettings, mediaDirectory: URL = cleanShotMediaDirectory) -> Bool {
    let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
    let isInExportFolder = folder.path == settings.exportDirectory.resolvingSymlinksInPath().path
    let isInHistory = folder.deletingLastPathComponent().path == mediaDirectory.resolvingSymlinksInPath().path
    return url.pathExtension.lowercased() == "webp" && (isInExportFolder || isInHistory) && settings.matchesName(url.lastPathComponent)
}

/// Waits until the file exists and its size stops changing. Returns its attributes, or `nil` after `fileTimeout`.
func waitForStableFile(_ url: URL, timing: ProcessingTiming) -> [FileAttributeKey: Any]? {
    let deadline = Date().addingTimeInterval(timing.fileTimeout)
    var previousSize = -1
    while Date() < deadline {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? Int {
            if size > 0 && size == previousSize { return attributes }
            previousSize = size
        }
        Thread.sleep(forTimeInterval: timing.pollInterval)
    }
    return nil
}

/// Converts a CleanShot WebP that was just copied to `pasteboard` and swaps the clipboard to the smaller of PNG/JPEG.
///
/// - A fresh capture or edit in the export folder also gets its conversion saved next to it (replacing an earlier one).
/// - An older file re-copied from CleanShot's history is converted on the clipboard only: an up-to-date
///   conversion on disk is reused, otherwise the clipboard gets just the image data and nothing is written.
///
/// - Parameter changeCount: The pasteboard's change count when the copy was detected. If it moves on, we back off.
public func processClipboardCopy(
    of url: URL,
    pasteboard: NSPasteboard,
    changeCount: Int,
    exportDirectory: URL,
    jpegQuality: Double = 0.85,
    timing: ProcessingTiming = ProcessingTiming()
) throws -> (result: ProcessingResult, candidates: [EncodedImage]) {
    guard let attributes = waitForStableFile(url, timing: timing) else { return (.fileMissing, []) }
    let candidates = encodeSmallestFirst(url, jpegQuality: jpegQuality)
    guard let smallest = candidates.first else { return (.encodingFailed, []) }
    guard pasteboard.changeCount == changeCount else { return (.clipboardChanged, candidates) }

    let modified = attributes[.modificationDate] as? Date ?? .distantPast
    let isInExportFolder = url.deletingLastPathComponent().resolvingSymlinksInPath().path == exportDirectory.resolvingSymlinksInPath().path
    let outputURL = url.deletingPathExtension().appendingPathExtension(smallest.fileExtension)

    if isInExportFolder && Date().timeIntervalSince(modified) < timing.freshSaveAge {
        try writeIfChanged(smallest.data, to: outputURL)
        removeStaleConversions(of: url, keeping: outputURL)
        writeImage(smallest, at: outputURL, to: pasteboard)
        return (.savedAndCopied(outputURL), candidates)
    }
    if isInExportFolder, hasContents(outputURL, smallest.data) {
        writeImage(smallest, at: outputURL, to: pasteboard)
        return (.copiedExisting(outputURL), candidates)
    }
    writeImage(smallest, at: nil, to: pasteboard)
    return (.copiedDataOnly, candidates)
}

/// Converts a WebP that CleanShot just saved (or re-saved after an edit) in its export folder, when it was not copied.
///
/// Waits `copyGrace` for CleanShot to copy the file too; if it does, the clipboard trigger owns the conversion.
/// Otherwise saves the conversion next to the WebP and leaves the clipboard alone.
/// - Parameter converted: The version the clipboard trigger already converted, if any.
public func processSavedFile(
    at url: URL,
    pasteboard: NSPasteboard,
    converted: FileVersion?,
    jpegQuality: Double = 0.85,
    timing: ProcessingTiming = ProcessingTiming()
) throws -> (result: ProcessingResult, candidates: [EncodedImage], version: FileVersion?) {
    guard let attributes = waitForStableFile(url, timing: timing), let version = FileVersion(attributes) else {
        return (.fileMissing, [], nil)
    }
    guard version != converted else { return (.alreadyConverted, [], version) }
    guard Date().timeIntervalSince(version.modified) < timing.freshSaveAge else { return (.notFresh, [], version) }
    let path = url.standardizedFileURL.path
    if poll(timeout: timing.copyGrace, interval: timing.pollInterval, { fileURLPath(on: pasteboard) == path }) {
        return (.leftToClipboard, [], version)
    }

    let candidates = encodeSmallestFirst(url, jpegQuality: jpegQuality)
    guard let smallest = candidates.first else { return (.encodingFailed, [], version) }
    let outputURL = url.deletingPathExtension().appendingPathExtension(smallest.fileExtension)
    try writeIfChanged(smallest.data, to: outputURL)
    removeStaleConversions(of: url, keeping: outputURL)
    return (.savedOnly(outputURL), candidates, version)
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

/// Writes `data` to `url` unless the file already holds exactly those bytes, so a re-encode of an unchanged image
/// doesn't touch the file, its timestamps, or the SSD. Returns whether it wrote.
@discardableResult
func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
    if hasContents(url, data) { return false }
    try data.write(to: url, options: .atomic)
    return true
}

/// Whether the file at `url` holds exactly `data`. Compares sizes first, then bytes via a memory-mapped read.
/// Also tells whether an existing conversion matches the current WebP, independent of timestamps.
func hasContents(_ url: URL, _ data: Data) -> Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    return size == data.count && (try? Data(contentsOf: url, options: .alwaysMapped)) == data
}
