/// Converts CleanShot X's WebP screenshots to the smaller of PNG/JPEG, however CleanShot hands them over:
/// - Copied (new captures, Annotate edits, history re-copies): swaps the clipboard, and saves fresh ones next to the WebP.
/// - Saved but not copied: saves the conversion next to the WebP.
/// Follows CleanShot's folder, format, filename, and overlay settings live.
import AppKit
import CleanShotWebPCore

let jpegQuality = 0.85
let clipboardPollInterval: TimeInterval = 0.25
let workQueue = DispatchQueue(label: "cleanshot-webp-converter")

func log(_ message: String) {
    print("\(Date().formatted(.iso8601)) \(message)")
    fflush(stdout)
}

/// Versions converted per path, shared by both triggers so a capture that's saved and copied converts once.
/// Only touched on `workQueue`.
nonisolated(unsafe) var convertedVersions: [String: FileVersion] = [:]

/// Shows the toast for a finished conversion.
func announce(_ url: URL, result: EncodedImage, isRecopy: Bool, settings: CleanShotSettings) {
    let sourceSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let summary = conversionSummary(sourceName: url.lastPathComponent, sourceSize: sourceSize, result: result, isRecopy: isRecopy)
    let isLeftEdge = settings.isOverlayOnLeftEdge
    Task { @MainActor in showToast(summary, isLeftEdge: isLeftEdge) }
}

/// Runs the conversion for one clipboard copy, logs the outcome, and shows a toast. Runs on `workQueue`.
func handleClipboardCopy(_ url: URL, changeCount: Int, settings: CleanShotSettings) {
    let name = url.lastPathComponent
    do {
        let (result, candidates) = try processClipboardCopy(
            of: url, pasteboard: .general, changeCount: changeCount, exportDirectory: settings.exportDirectory, jpegQuality: jpegQuality
        )
        let sizes = candidates.map { "\($0.fileExtension)=\($0.data.count)B" }.joined(separator: ", ")
        let isRecopy: Bool
        switch result {
        case .fileMissing: return log("\(name): file never appeared, skipping")
        case .clipboardChanged: return log("\(name): clipboard changed meanwhile, left alone")
        case .encodingFailed: return log("\(name): encoding failed")
        case .savedAndCopied(let output):
            log("\(name): \(sizes) -> \(output.lastPathComponent), saved and copied")
            convertedVersions[url.path] = FileVersion(of: url)
            isRecopy = false
        case .copiedExisting(let output):
            log("\(name): re-copied, swapped clipboard to existing \(output.lastPathComponent)")
            isRecopy = true
        case .copiedDataOnly:
            log("\(name): re-copied, \(sizes) -> \(candidates[0].fileExtension) on clipboard only")
            isRecopy = true
        case .savedOnly, .leftToClipboard, .alreadyConverted, .notFresh: return
        }
        announce(url, result: candidates[0], isRecopy: isRecopy, settings: settings)
    } catch {
        log("\(name): \(error.localizedDescription)")
    }
}

/// Handles a WebP that CleanShot saved or re-saved; converts it only if CleanShot didn't also copy it. Runs on `workQueue`.
func handleSavedFile(_ url: URL, settings: CleanShotSettings) {
    let name = url.lastPathComponent
    do {
        let (result, candidates, version) = try processSavedFile(
            at: url, pasteboard: .general, converted: convertedVersions[url.path], jpegQuality: jpegQuality
        )
        guard case .savedOnly(let output) = result else { return }
        convertedVersions[url.path] = version
        log("\(name): \(candidates.map { "\($0.fileExtension)=\($0.data.count)B" }.joined(separator: ", ")) -> \(output.lastPathComponent), saved (not copied)")
        announce(url, result: candidates[0], isRecopy: false, settings: settings)
    } catch {
        log("\(name): \(error.localizedDescription)")
    }
}

/// Forwards KVO notifications for a set of `UserDefaults` keys to a closure.
/// Fires for changes made by other processes too, i.e. when you edit CleanShot's settings.
final class DefaultsObserver: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: @Sendable () -> Void

    init(defaults: UserDefaults, keys: [String], onChange: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.onChange = onChange
        super.init()
        keys.forEach { defaults.addObserver(self, forKeyPath: $0, context: nil) }
    }

    deinit { keys.forEach { defaults.removeObserver(self, forKeyPath: $0) } }

    override func observeValue(forKeyPath _: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) {
        onChange()
    }
}

/// Delivers file-level FSEvents (creations, in-place edits, renames) under one directory to a closure on the main queue.
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let onEvent: (String) -> Void

    init?(directory: URL, onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let events = Unmanaged<FileEventStream>.fromOpaque(info!).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            for index in 0..<count where flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 {
                events.onEvent(paths[index])
            }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, FSEventStreamCreateFlags(flags)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}


/// Watches both ways CleanShot hands over a capture and re-points itself whenever CleanShot's settings change:
/// - The clipboard, by polling its change count (macOS has no clipboard notification). Our own replacements point
///   at a PNG/JPEG or carry no file, so they never re-trigger.
/// - The export folder, via FSEvents, for captures saved without being copied.
@MainActor
final class CleanShotWatcher {
    private var settings: CleanShotSettings?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var folderEvents: FileEventStream?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: clipboardPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func apply(_ newSettings: CleanShotSettings) {
        guard newSettings != settings else { return }
        let isNewDirectory = newSettings.exportDirectory != settings?.exportDirectory
        settings = newSettings
        if isNewDirectory { watchFolder(newSettings.exportDirectory) }
        log("CleanShot saves \(newSettings.screenshotFormat) to \(newSettings.exportDirectory.path), name template \(newSettings.nameTemplate.joined())")
        if !newSettings.savesWebP { log("not WebP, idling until CleanShot switches to WebP") }
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let settings, settings.savesWebP, let path = fileURLPath(on: pasteboard) else { return }
        let url = URL(fileURLWithPath: path)
        guard isCleanShotWebP(url, settings: settings) else { return }
        workQueue.async { handleClipboardCopy(url, changeCount: changeCount, settings: settings) }
    }

    private func watchFolder(_ directory: URL) {
        folderEvents = FileEventStream(directory: directory) { [weak self] path in
            MainActor.assumeIsolated { self?.fileChanged(path) }
        }
        if folderEvents == nil { log("cannot watch \(directory.path)") }
    }

    private func fileChanged(_ path: String) {
        guard let settings, settings.savesWebP else { return }
        let changedURL = URL(fileURLWithPath: path)
        // Use CleanShot's spelling of the folder (FSEvents reports real paths such as /private/tmp), so it matches the clipboard.
        let url = settings.exportDirectory.appendingPathComponent(changedURL.lastPathComponent)
        guard changedURL.deletingLastPathComponent().resolvingSymlinksInPath().path == settings.exportDirectory.resolvingSymlinksInPath().path,
              isCleanShotWebP(url, settings: settings)
        else { return }
        workQueue.async { handleSavedFile(url, settings: settings) }
    }
}

let defaults = cleanShotDefaults()
let watcher = CleanShotWatcher()
watcher.apply(CleanShotSettings(defaults: defaults))
watcher.start()
let observer = DefaultsObserver(defaults: defaults, keys: CleanShotKey.all) {
    Task { @MainActor in watcher.apply(CleanShotSettings(defaults: defaults)) }
}

// An app run loop (not dispatchMain) is required for cross-process preference notifications, the timer, and the toast.
// Accessory apps can show windows without a Dock icon.
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
