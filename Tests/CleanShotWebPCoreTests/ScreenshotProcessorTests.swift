import AppKit
import UniformTypeIdentifiers
import Testing
@testable import CleanShotWebPCore

/// Gives each test a private pasteboard and temp folder, so tests never touch your real clipboard or Downloads.
struct Sandbox: ~Copyable {
    let pasteboard = NSPasteboard(name: .init("cleanshot-webp-converter.tests.\(UUID().uuidString)"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// Fast timings so the negative paths don't wait five seconds.
    let timing = {
        var timing = ProcessingTiming()
        timing.clipboardTimeout = 0.3
        timing.pollInterval = 0.05
        return timing
    }()

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a fresh copy of a fixture, like CleanShot saving a new capture.
    func capture(_ fixture: String, as name: String = "2026-09-28 5-12-29 PM.webp") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contentsOf: fixtureURL(fixture)).write(to: url)
        return url
    }

    /// Puts a file URL on the pasteboard, like CleanShot's "Copy" after-capture action.
    func copyToClipboard(_ url: URL) {
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .fileURL)
    }
}

@Suite struct ScreenshotProcessorTests {
    @Test func convertsAndReplacesClipboard() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        sandbox.copyToClipboard(webp)

        let (result, candidates) = try processScreenshot(at: webp, pasteboard: sandbox.pasteboard, timing: sandbox.timing)

        let jpeg = webp.deletingPathExtension().appendingPathExtension("jpg")
        #expect(result == .savedAndCopied(jpeg))
        #expect(candidates.count == 2)
        #expect(FileManager.default.fileExists(atPath: webp.path), "original must be kept")
        #expect(try Data(contentsOf: jpeg) == candidates[0].data)
        #expect(fileURLPath(on: sandbox.pasteboard) == jpeg.standardizedFileURL.path)
        #expect(sandbox.pasteboard.data(forType: .init(UTType.jpeg.identifier)) == candidates[0].data)
    }

    @Test func skipsFilesNotOnClipboard() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        sandbox.copyToClipboard(URL(fileURLWithPath: "/somewhere/else.webp"))

        let (result, _) = try processScreenshot(at: webp, pasteboard: sandbox.pasteboard, timing: sandbox.timing)

        #expect(result == .notOnClipboard)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path) == [webp.lastPathComponent])
    }

    @Test func ignoresOldFiles() throws {
        let sandbox = try Sandbox()
        let webp = try sandbox.capture("photo")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: webp.path)
        sandbox.copyToClipboard(webp)

        let (result, _) = try processScreenshot(at: webp, pasteboard: sandbox.pasteboard, timing: sandbox.timing)

        #expect(result == .notNew)
    }

    @Test func ignoresDeletedFiles() throws {
        let sandbox = try Sandbox()
        let (result, _) = try processScreenshot(
            at: sandbox.directory.appendingPathComponent("gone.webp"), pasteboard: sandbox.pasteboard, timing: sandbox.timing
        )
        #expect(result == .notNew)
    }
}
