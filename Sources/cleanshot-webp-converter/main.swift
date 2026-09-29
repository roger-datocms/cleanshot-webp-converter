/// Watches CleanShot X's export folder for new WebP screenshots. When the clipboard points at the new file,
/// saves the smaller of a PNG/JPEG re-encode next to it and puts that copy on the clipboard instead.
/// Follows CleanShot's folder, format, and filename settings live.
import AppKit
import CleanShotWebPCore

let jpegQuality = 0.85
let workQueue = DispatchQueue(label: "cleanshot-webp-converter")

func log(_ message: String) {
    print("\(Date().formatted(.iso8601)) \(message)")
    fflush(stdout)
}

/// Last handled version per path. FSEvents reports several events per save, and this collapses them.
/// Only touched on `workQueue`.
nonisolated(unsafe) var handledVersions: [String: FileVersion] = [:]

/// Runs the conversion pipeline for one file, logs the outcome, and shows a toast next to CleanShot's overlay.
/// Runs on `workQueue`.
func handle(_ url: URL, isOverlayOnLeftEdge: Bool) {
    let name = url.lastPathComponent
    guard let version = FileVersion(of: url), handledVersions[url.path] != version else { return }
    defer { handledVersions[url.path] = FileVersion(of: url) }
    do {
        let (result, candidates) = try processScreenshot(at: url, pasteboard: .general, jpegQuality: jpegQuality)
        let sizes = candidates.map { "\($0.fileExtension)=\($0.data.count)B" }.joined(separator: ", ")
        switch result {
        case .notRecent: break
        case .notOnClipboard: log("\(name): not on clipboard, skipping")
        case .encodingFailed: log("\(name): encoding failed")
        case .savedOnly(let output): log("\(name): \(sizes) -> \(output.lastPathComponent) (clipboard changed, left alone)")
        case .savedAndCopied(let output):
            log("\(name): \(sizes) -> \(output.lastPathComponent), copied")
            let sourceSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let summary = conversionSummary(sourceName: name, sourceSize: sourceSize, result: candidates[0])
            Task { @MainActor in showToast(summary, isLeftEdge: isOverlayOnLeftEdge) }
        }
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

/// Owns the folder watch and re-points it whenever CleanShot's settings change.
@MainActor
final class ExportFolderWatcher {
    private var settings: CleanShotSettings?
    private var events: FileEventStream?

    func apply(_ newSettings: CleanShotSettings) {
        guard newSettings != settings else { return }
        let isNewDirectory = newSettings.exportDirectory != settings?.exportDirectory
        settings = newSettings
        log("CleanShot saves \(newSettings.screenshotFormat) to \(newSettings.exportDirectory.path), name template \(newSettings.nameTemplate.joined())")
        if !newSettings.savesWebP { log("not WebP, idling until CleanShot switches to WebP") }
        if isNewDirectory { watch(newSettings.exportDirectory) }
    }

    private func watch(_ directory: URL) {
        events = FileEventStream(directory: directory) { [weak self] path in
            MainActor.assumeIsolated { self?.fileChanged(path) }
        }
        if events == nil { log("cannot watch \(directory.path)") }
    }

    private func fileChanged(_ path: String) {
        guard let settings, settings.savesWebP else { return }
        let changedURL = URL(fileURLWithPath: path)
        // FSEvents reports real paths (e.g. /private/tmp), CleanShot's setting may use a symlinked one.
        guard changedURL.pathExtension.lowercased() == "webp",
              changedURL.deletingLastPathComponent().resolvingSymlinksInPath() == settings.exportDirectory.resolvingSymlinksInPath(),
              settings.matchesName(changedURL.lastPathComponent)
        else { return }
        // Use CleanShot's spelling of the folder, since that's what it puts on the clipboard.
        let url = settings.exportDirectory.appendingPathComponent(changedURL.lastPathComponent)
        let isOverlayOnLeftEdge = settings.isOverlayOnLeftEdge
        workQueue.async { handle(url, isOverlayOnLeftEdge: isOverlayOnLeftEdge) }
    }
}

let defaults = cleanShotDefaults()
let watcher = ExportFolderWatcher()
watcher.apply(CleanShotSettings(defaults: defaults))
let observer = DefaultsObserver(defaults: defaults, keys: CleanShotKey.all) {
    Task { @MainActor in watcher.apply(CleanShotSettings(defaults: defaults)) }
}

// An app run loop (not dispatchMain) is required for cross-process preference notifications and the toast.
// Accessory apps can show windows without a Dock icon.
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
