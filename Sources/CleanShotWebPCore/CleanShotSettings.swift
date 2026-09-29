import Foundation

/// CleanShot X's preference domains: direct download first, then the Setapp build.
public let cleanShotDomains = ["pl.maketheweb.cleanshotx", "pl.maketheweb.cleanshotx-setapp"]

/// Preference keys CleanShot uses. They are undocumented, so this is the single place to update if CleanShot renames them.
public enum CleanShotKey {
    public static let exportPath = "exportPath"
    public static let screenshotFormat = "screenshotFormat"
    public static let nameTemplate = "mediaNameTemplate"
    public static let overlayOnLeftEdge = "popupOnLeftEdge"
    public static let all = [exportPath, screenshotFormat, nameTemplate, overlayOnLeftEdge]
}

/// The subset of CleanShot's preferences that decides where screenshots land, what they're called,
/// and which screen edge its Quick Access Overlay uses.
public struct CleanShotSettings: Equatable, Sendable {
    public var exportDirectory: URL
    public var screenshotFormat: String
    /// Tokens such as `["%y", "-", "%m"]`; empty when CleanShot hasn't stored one.
    public var nameTemplate: [String]
    public var isOverlayOnLeftEdge: Bool

    public init(exportDirectory: URL, screenshotFormat: String, nameTemplate: [String], isOverlayOnLeftEdge: Bool = false) {
        self.exportDirectory = exportDirectory.standardizedFileURL
        self.screenshotFormat = screenshotFormat
        self.nameTemplate = nameTemplate
        self.isOverlayOnLeftEdge = isOverlayOnLeftEdge
    }

    /// Reads settings from `defaults`, falling back to CleanShot's factory defaults (Desktop, PNG, overlay on the right).
    public init(defaults: UserDefaults) {
        let path = defaults.string(forKey: CleanShotKey.exportPath) ?? "~/Desktop"
        self.init(
            exportDirectory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
            screenshotFormat: defaults.string(forKey: CleanShotKey.screenshotFormat) ?? "png",
            nameTemplate: defaults.stringArray(forKey: CleanShotKey.nameTemplate) ?? [],
            isOverlayOnLeftEdge: defaults.bool(forKey: CleanShotKey.overlayOnLeftEdge)
        )
    }

    public var savesWebP: Bool { screenshotFormat.lowercased() == "webp" }

    /// Whether `fileName` (with or without extension) could have come from `nameTemplate`.
    public func matchesName(_ fileName: String) -> Bool {
        guard !nameTemplate.isEmpty, let regex = try? Regex(Self.pattern(for: nameTemplate)) else { return true }
        let baseName = (fileName as NSString).deletingPathExtension
        return baseName.wholeMatch(of: regex) != nil
    }

    /// Converts a CleanShot name template into a regex pattern.
    /// Numeric date/time tokens become digit runs, AM/PM becomes a word, unknown tokens match anything.
    static func pattern(for template: [String]) -> String {
        let body = template.map { token -> String in
            switch token {
            case "%y", "%m", "%d", "%H", "%M", "%S": #"\d{1,4}"#
            case "%p": #"\S+"#
            case _ where token.hasPrefix("%"): ".+?"
            default: NSRegularExpression.escapedPattern(for: token)
            }
        }.joined()
        // Tolerate a de-duplication suffix like " (2)" or "-2".
        return body + #"(?:[ _-]?\(?\d+\)?)?"#
    }
}

/// Returns the first CleanShot preference domain that has an export path, or the default domain.
public func cleanShotDefaults() -> UserDefaults {
    let suites = cleanShotDomains.compactMap(UserDefaults.init(suiteName:))
    return suites.first { $0.string(forKey: CleanShotKey.exportPath) != nil } ?? suites[0]
}
