import Foundation
import Testing
@testable import CleanShotWebPCore

/// A throwaway `UserDefaults` suite, so tests never touch CleanShot's real preferences.
func withScratchDefaults(_ values: [String: Any], _ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "cleanshot-webp-converter.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    values.forEach { defaults.set($1, forKey: $0) }
    try body(defaults)
}

/// CleanShot's stock "2026-09-28 5-12-29 PM" style template.
let dateTemplate = ["%y", "-", "%m", "-", "%d", " ", "%H", "-", "%M", "-", "%S", " ", "%p"]

@Suite struct CleanShotSettingsTests {
    @Test func readsCleanShotPreferences() {
        withScratchDefaults([
            CleanShotKey.exportPath: "/Users/someone/Screenshots",
            CleanShotKey.screenshotFormat: "webp",
            CleanShotKey.nameTemplate: dateTemplate,
        ]) { defaults in
            let settings = CleanShotSettings(defaults: defaults)
            #expect(settings.exportDirectory.path == "/Users/someone/Screenshots")
            #expect(settings.savesWebP)
            #expect(settings.nameTemplate == dateTemplate)
        }
    }

    @Test func fallsBackToCleanShotFactoryDefaults() {
        withScratchDefaults([:]) { defaults in
            let settings = CleanShotSettings(defaults: defaults)
            #expect(settings.exportDirectory.path == NSHomeDirectory() + "/Desktop")
            #expect(!settings.savesWebP)
            #expect(settings.nameTemplate.isEmpty)
        }
    }

    @Test(arguments: ["webp", "WebP", "WEBP"])
    func detectsWebPCaseInsensitively(format: String) {
        let settings = CleanShotSettings(exportDirectory: URL(fileURLWithPath: "/tmp"), screenshotFormat: format, nameTemplate: [])
        #expect(settings.savesWebP)
    }

    @Test(arguments: [
        ("2026-09-28 5-12-29 PM.webp", true),
        ("2026-09-28 05-12-29 AM", true),
        ("2026-09-28 5-12-29 PM (2).webp", true),
        ("2026-09-28 5-12-29 PM-3.webp", true),
        ("IMG_1234.webp", false),
        ("notes.webp", false),
        ("2026-09-28 5-12-29.webp", false),
    ])
    func matchesDateTemplate(fileName: String, isMatch: Bool) {
        let settings = CleanShotSettings(exportDirectory: URL(fileURLWithPath: "/tmp"), screenshotFormat: "webp", nameTemplate: dateTemplate)
        #expect(settings.matchesName(fileName) == isMatch)
    }

    @Test func escapesRegexCharactersInLiterals() {
        let settings = CleanShotSettings(exportDirectory: URL(fileURLWithPath: "/tmp"), screenshotFormat: "webp", nameTemplate: ["Shot.", "%y"])
        #expect(settings.matchesName("Shot.2026.webp"))
        #expect(!settings.matchesName("ShotX2026.webp"))
    }

    @Test func unknownTokensMatchAnything() {
        let settings = CleanShotSettings(exportDirectory: URL(fileURLWithPath: "/tmp"), screenshotFormat: "webp", nameTemplate: ["CleanShot ", "%z"])
        #expect(settings.matchesName("CleanShot Safari window.webp"))
        #expect(!settings.matchesName("Other Safari window.webp"))
    }

    @Test func emptyTemplateMatchesEverything() {
        let settings = CleanShotSettings(exportDirectory: URL(fileURLWithPath: "/tmp"), screenshotFormat: "webp", nameTemplate: [])
        #expect(settings.matchesName("anything at all.webp"))
    }
}
