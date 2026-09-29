import AppKit

/// Outcome of handling one CleanShot WebP copied to the clipboard, for logging and tests.
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
}

/// Timing knobs, overridable in tests.
public struct ProcessingTiming: Sendable {
    /// How long to wait for the copied file to appear and finish writing.
    public var fileTimeout: TimeInterval = 5
    /// Files saved more recently than this count as a fresh capture or edit and get a converted copy on disk.
    public var freshSaveAge: TimeInterval = 30
    public var pollInterval: TimeInterval = 0.25

    public init() {}
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
        try smallest.data.write(to: outputURL, options: .atomic)
        removeStaleConversions(of: url, keeping: outputURL)
        writeImage(smallest, at: outputURL, to: pasteboard)
        return (.savedAndCopied(outputURL), candidates)
    }
    if isInExportFolder, isUpToDateConversion(outputURL, of: modified) {
        writeImage(smallest, at: outputURL, to: pasteboard)
        return (.copiedExisting(outputURL), candidates)
    }
    writeImage(smallest, at: nil, to: pasteboard)
    return (.copiedDataOnly, candidates)
}

/// Whether `conversion` exists and was written after the source's last save.
func isUpToDateConversion(_ conversion: URL, of sourceModified: Date) -> Bool {
    let modified = (try? FileManager.default.attributesOfItem(atPath: conversion.path))?[.modificationDate] as? Date
    return modified.map { $0 >= sourceModified } ?? false
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
