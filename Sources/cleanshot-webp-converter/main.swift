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

/// Runs the conversion pipeline for one file, logs the outcome, and shows a toast next to CleanShot's overlay.
func handle(_ url: URL, isOverlayOnLeftEdge: Bool) {
    let name = url.lastPathComponent
    do {
        let (result, candidates) = try processScreenshot(at: url, pasteboard: .general, jpegQuality: jpegQuality)
        let sizes = candidates.map { "\($0.fileExtension)=\($0.data.count)B" }.joined(separator: ", ")
        switch result {
        case .notNew: break
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

/// Owns the directory watch and re-points it whenever CleanShot's settings change.
@MainActor
final class ExportFolderWatcher {
    private var settings: CleanShotSettings?
    private var source: DispatchSourceFileSystemObject?
    private var knownNames: Set<String> = []

    func apply(_ newSettings: CleanShotSettings) {
        guard newSettings != settings else { return }
        let isNewDirectory = newSettings.exportDirectory != settings?.exportDirectory
        settings = newSettings
        log("CleanShot saves \(newSettings.screenshotFormat) to \(newSettings.exportDirectory.path), name template \(newSettings.nameTemplate.joined())")
        if !newSettings.savesWebP { log("not WebP, idling until CleanShot switches to WebP") }
        if isNewDirectory { watch(newSettings.exportDirectory) }
    }

    private func watch(_ directory: URL) {
        source?.cancel()
        source = nil
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log("cannot watch \(directory.path): \(String(cString: strerror(errno)))")
            return
        }
        knownNames = webpNames(in: directory)
        // A directory vnode fires on any entry change; diffing the listing tells us which WebPs are new.
        let newSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        newSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        newSource.setCancelHandler { close(descriptor) }
        newSource.resume()
        source = newSource
    }

    private func scan() {
        guard let settings else { return }
        let currentNames = webpNames(in: settings.exportDirectory)
        let newNames = currentNames.subtracting(knownNames)
        knownNames = currentNames
        guard settings.savesWebP else { return }
        for name in newNames where settings.matchesName(name) {
            let url = settings.exportDirectory.appendingPathComponent(name)
            let isOverlayOnLeftEdge = settings.isOverlayOnLeftEdge
            workQueue.async { handle(url, isOverlayOnLeftEdge: isOverlayOnLeftEdge) }
        }
    }

    private func webpNames(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.lowercased().hasSuffix(".webp") })
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
