import AppKit
import UniformTypeIdentifiers
import Testing
@testable import CleanShotWebPCore

/// Gives each test a private pasteboard and temp folders, so tests never touch your real clipboard, Downloads,
/// or CleanShot's history.
struct Sandbox: ~Copyable {
    let pasteboard = NSPasteboard(name: .init("cleanshot-webp-converter.tests.\(UUID().uuidString)"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var exportDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    var mediaDirectory: URL { root.appendingPathComponent("media", isDirectory: true) }

    /// Fast timings so the negative paths don't wait five seconds.
    let timing = {
        var timing = ProcessingTiming()
        timing.fileTimeout = 0.3
        timing.pollInterval = 0.05
        return timing
    }()

    init() throws {
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    }

    deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    var settings: CleanShotSettings {
        CleanShotSettings(exportDirectory: exportDirectory, screenshotFormat: "webp", nameTemplate: dateTemplate)
    }

    /// Writes a fresh copy of a fixture, like CleanShot saving a new capture.
    func capture(_ fixture: String, as name: String = "2026-09-28 5-12-29 PM.webp", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? exportDirectory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: fixtureURL(fixture)).write(to: url)
        return url
    }

    /// Backdates a file, turning it into an old capture that CleanShot's history can re-copy.
    func age(_ url: URL) throws {
        let hourAgo = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.creationDate: hourAgo, .modificationDate: hourAgo], ofItemAtPath: url.path)
    }

    /// Puts a file URL on the pasteboard, like CleanShot's "Copy" action. Returns the resulting change count.
    @discardableResult
    func copyToClipboard(_ url: URL) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .fileURL)
        return pasteboard.changeCount
    }

    func process(_ url: URL, changeCount: Int) throws -> (result: ProcessingResult, candidates: [EncodedImage]) {
        try processClipboardCopy(of: url, pasteboard: pasteboard, changeCount: changeCount, exportDirectory: exportDirectory, timing: timing)
    }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).sorted()
    }
}

@Suite struct ScreenshotProcessorTests {
    @Test func freshCaptureIsSavedAndCopied() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")

        let (result, candidates) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")
        #expect(result == .savedAndCopied(jpeg))
        #expect(FileManager.default.fileExists(atPath: webp.path), "original must be kept")
        #expect(try Data(contentsOf: jpeg) == candidates[0].data)
        #expect(fileURLPath(on: sandbox.pasteboard) == jpeg.standardizedFileURL.path)
        #expect(sandbox.pasteboard.data(forType: .init(UTType.jpeg.identifier)) == candidates[0].data)
    }

    /// CleanShot's Annotate tool re-saves the same WebP in place and copies it again.
    @Test func editedCaptureIsReconvertedAndStaleFormatDropped() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        _ = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))
        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")

        // Overwrite in place (same inode, old creation date), as an Annotate save does.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: webp.path)
        try Data(contentsOf: fixtureURL("graphic")).write(to: webp)
        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        let png = webp.deletingPathExtension().appendingPathExtension("png")
        #expect(result == .savedAndCopied(png))
        #expect(!FileManager.default.fileExists(atPath: jpeg.path), "the pre-edit JPEG is stale")
        #expect(fileURLPath(on: sandbox.pasteboard) == png.standardizedFileURL.path)
    }

    @Test func historyRecopyReusesUpToDateConversion() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        _ = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))
        try sandbox.age(webp)
        let before = try sandbox.files()

        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")
        #expect(result == .copiedExisting(jpeg))
        #expect(try sandbox.files() == before, "nothing new on disk")
        #expect(fileURLPath(on: sandbox.pasteboard) == jpeg.standardizedFileURL.path)
    }

    @Test func historyRecopyWithoutConversionIsClipboardOnly() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        try sandbox.age(webp)

        let (result, candidates) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        #expect(result == .copiedDataOnly)
        #expect(try sandbox.files() == [webp.lastPathComponent], "nothing written to disk")
        #expect(fileURLPath(on: sandbox.pasteboard) == nil, "no file link, so apps paste the image data")
        #expect(sandbox.pasteboard.data(forType: .init(UTType.jpeg.identifier)) == candidates[0].data)
    }

    @Test func historyRecopyIgnoresConversionThatNoLongerMatches() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")
        try Data("pre-edit".utf8).write(to: jpeg)
        try sandbox.age(webp)

        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        #expect(result == .copiedDataOnly)
        #expect(try Data(contentsOf: jpeg) == Data("pre-edit".utf8), "left alone")
    }

    /// Matching is by content, so a conversion older than a no-op re-save of the WebP is still reused.
    @Test func historyRecopyReusesMatchingConversionRegardlessOfTimestamps() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        _ = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))
        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")
        try sandbox.age(webp)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: jpeg.path)

        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        #expect(result == .copiedExisting(jpeg))
    }

    /// A re-save that encodes to identical bytes leaves the conversion on disk untouched.
    @Test func identicalReencodeDoesNotRewriteTheFile() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        _ = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))
        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")
        try sandbox.age(jpeg)
        let before = try FileManager.default.attributesOfItem(atPath: jpeg.path)

        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: webp.path)
        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        let after = try FileManager.default.attributesOfItem(atPath: jpeg.path)
        #expect(result == .savedAndCopied(jpeg))
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int, "same inode, so not replaced")
    }

    @Test func writeIfChangedSkipsIdenticalBytesOnly() throws {
        let sandbox = try Sandbox()
        let url = sandbox.exportDirectory.appendingPathComponent("out.png")
        #expect(try writeIfChanged(Data([1, 2, 3]), to: url))
        #expect(try !writeIfChanged(Data([1, 2, 3]), to: url))
        #expect(try writeIfChanged(Data([1, 2, 4]), to: url), "same size, different bytes")
        #expect(try writeIfChanged(Data([1, 2]), to: url), "different size")
        #expect(try Data(contentsOf: url) == Data([1, 2]))
    }

    /// Even a brand-new file in CleanShot's history storage is never written next to.
    @Test func historyStorageCopyIsClipboardOnly() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo", in: sandbox.mediaDirectory.appendingPathComponent("media_abc123"))

        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        #expect(result == .copiedDataOnly)
        #expect(try FileManager.default.contentsOfDirectory(atPath: webp.deletingLastPathComponent().path) == [webp.lastPathComponent])
    }

    @Test func backsOffWhenClipboardChangesMeanwhile() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        let changeCount = sandbox.copyToClipboard(webp)
        sandbox.pasteboard.clearContents()
        sandbox.pasteboard.setString("something else", forType: .string)

        let (result, _) = try sandbox.process(webp, changeCount: changeCount)

        #expect(result == .clipboardChanged)
        #expect(sandbox.pasteboard.string(forType: .string) == "something else")
        #expect(try sandbox.files() == [webp.lastPathComponent])
    }

    @Test func reportsMissingFile() throws {
        let sandbox = try Sandbox()
        let webp = sandbox.exportDirectory.appendingPathComponent("2026-09-28 5-12-29 PM.webp")
        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))
        #expect(result == .fileMissing)
    }

    @Test func keepsUnrelatedOlderSiblings() throws {
        let sandbox = try Sandbox()
        let olderPNG = sandbox.exportDirectory.appendingPathComponent("2026-09-28 5-12-29 PM.png")
        try Data("not ours".utf8).write(to: olderPNG)
        try sandbox.age(olderPNG)
        let webp = try sandbox.capture("photo")

        let (result, _) = try sandbox.process(webp, changeCount: sandbox.copyToClipboard(webp))

        #expect(result == .savedAndCopied(webp.deletingPathExtension().appendingPathExtension("jpg")))
        #expect(try Data(contentsOf: olderPNG) == Data("not ours".utf8))
    }

    @Test func fileURLPathNeverReadsNonFileContents() {
        let pasteboard = NSPasteboard(name: .init("cleanshot-webp-converter.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("file:///looks/like/a/url.webp", forType: .string)
        #expect(fileURLPath(on: pasteboard) == nil)
    }
}

@Suite struct CleanShotWebPDetectionTests {
    let settings = CleanShotSettings(exportDirectory: URL(fileURLWithPath: "/Users/someone/Downloads"), screenshotFormat: "webp", nameTemplate: dateTemplate)
    let media = URL(fileURLWithPath: "/Users/someone/Library/Application Support/CleanShot/media")

    @Test(arguments: [
        ("/Users/someone/Downloads/2026-09-28 5-12-29 PM.webp", true),
        ("/Users/someone/Library/Application Support/CleanShot/media/media_i3MHYCMWW5/2026-09-28 5-12-29 PM.webp", true),
        ("/Users/someone/Downloads/2026-09-28 5-12-29 PM.png", false),
        ("/Users/someone/Downloads/cat.webp", false),
        ("/Users/someone/Desktop/2026-09-28 5-12-29 PM.webp", false),
        ("/Users/someone/Downloads/nested/2026-09-28 5-12-29 PM.webp", false),
        ("/Users/someone/Library/Application Support/CleanShot/media/media_x/2026-09-28 5-12-29 PM.cleanshot", false),
    ])
    func recognizesCleanShotFiles(path: String, isCleanShot: Bool) {
        #expect(isCleanShotWebP(URL(fileURLWithPath: path), settings: settings, mediaDirectory: media) == isCleanShot)
    }
}

/// CleanShot's "Save" and "Copy" after-capture actions are independent; these cover a save without a copy.
@Suite struct SavedFileTests {
    func processSaved(_ sandbox: borrowing Sandbox, _ url: URL, converted: FileVersion? = nil) throws -> (result: ProcessingResult, candidates: [EncodedImage], version: FileVersion?) {
        var timing = sandbox.timing
        timing.copyGrace = 0.2
        return try processSavedFile(at: url, pasteboard: sandbox.pasteboard, converted: converted, timing: timing)
    }

    @Test func saveWithoutCopySavesConversionAndLeavesClipboard() throws {
        let sandbox = try Sandbox()
        sandbox.pasteboard.clearContents()
        sandbox.pasteboard.setString("unrelated", forType: .string)
        let webp = try sandbox.capture("photo")

        let (result, _, version) = try processSaved(sandbox, webp)

        #expect(result == .savedOnly(webp.deletingPathExtension().appendingPathExtension("jpg")))
        #expect(version == FileVersion(of: webp))
        #expect(sandbox.pasteboard.string(forType: .string) == "unrelated")
    }

    @Test func saveWithCopyIsLeftToTheClipboardTrigger() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        sandbox.copyToClipboard(webp)

        let (result, _, _) = try processSaved(sandbox, webp)

        #expect(result == .leftToClipboard)
        #expect(try sandbox.files() == [webp.lastPathComponent])
    }

    @Test func skipsVersionTheClipboardTriggerConverted() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        let (result, _, _) = try processSaved(sandbox, webp, converted: FileVersion(of: webp))
        #expect(result == .alreadyConverted)
    }

    @Test func ignoresFilesNotSavedRecently() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        try sandbox.age(webp)
        let (result, _, _) = try processSaved(sandbox, webp)
        #expect(result == .notFresh)
    }

    @Test func fileVersionChangesWhenEdited() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        let original = try #require(FileVersion(of: webp))
        try Data(contentsOf: fixtureURL("graphic")).write(to: webp)
        #expect(FileVersion(of: webp) != original)
        #expect(FileVersion(of: sandbox.exportDirectory.appendingPathComponent("missing.webp")) == nil)
    }
}
