/// Watches the clipboard for WebP screenshots copied by CleanShot X (new captures, Annotate edits, history re-copies)
/// and swaps them for the smaller of a PNG/JPEG re-encode. Fresh captures and edits also get that copy saved next
/// to the WebP. Follows CleanShot's folder, format, filename, and overlay settings live.
import AppKit
import CleanShotWebPCore

let jpegQuality = 0.85
let clipboardPollInterval: TimeInterval = 0.25
let workQueue = DispatchQueue(label: "cleanshot-webp-converter")

func log(_ message: String) {
    print("\(Date().formatted(.iso8601)) \(message)")
    fflush(stdout)
}

/// Runs the conversion for one clipboard copy, logs the outcome, and shows a toast. Runs on `workQueue`.
func handle(_ url: URL, changeCount: Int, settings: CleanShotSettings) {
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
            isRecopy = false
        case .copiedExisting(let output):
            log("\(name): re-copied, swapped clipboard to existing \(output.lastPathComponent)")
            isRecopy = true
        case .copiedDataOnly:
            log("\(name): re-copied, \(sizes) -> \(candidates[0].fileExtension) on clipboard only")
            isRecopy = true
        }
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let summary = conversionSummary(sourceName: name, sourceSize: sourceSize, result: candidates[0], isRecopy: isRecopy)
        let isLeftEdge = settings.isOverlayOnLeftEdge
        Task { @MainActor in showToast(summary, isLeftEdge: isLeftEdge) }
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

/// Polls the clipboard's change count (macOS has no clipboard notification) and dispatches CleanShot WebP copies.
/// Our own replacements point at a PNG/JPEG or carry no file, so they never re-trigger.
@MainActor
final class ClipboardWatcher {
    private var settings: CleanShotSettings?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: clipboardPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func apply(_ newSettings: CleanShotSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
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
        workQueue.async { handle(url, changeCount: changeCount, settings: settings) }
    }
}

let defaults = cleanShotDefaults()
let watcher = ClipboardWatcher()
watcher.apply(CleanShotSettings(defaults: defaults))
watcher.start()
let observer = DefaultsObserver(defaults: defaults, keys: CleanShotKey.all) {
    Task { @MainActor in watcher.apply(CleanShotSettings(defaults: defaults)) }
}

// An app run loop (not dispatchMain) is required for cross-process preference notifications, the timer, and the toast.
// Accessory apps can show windows without a Dock icon.
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
