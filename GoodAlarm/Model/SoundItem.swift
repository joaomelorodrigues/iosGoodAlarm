import Foundation

nonisolated struct SoundItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case system, builtIn, imported
    }

    var id: String
    var name: String
    var subtitle: String
    var kind: Kind
    /// File inside `AppPaths.soundLibrary`; nil for the iPhone's own alarm sound.
    var fileName: String?
    var duration: Double

    var isFileBased: Bool { fileName != nil }

    static let systemID = "system-default"
    static let defaultID = "builtin-sunrise"
}

nonisolated enum AppPaths {
    static let support: URL = directory(URL.applicationSupportDirectory.appending(path: "GoodAlarm"))
    /// Imported and built-in sounds, full length.
    static let soundLibrary: URL = directory(support.appending(path: "Sounds"))
    /// Where AlarmKit looks for named sounds (the rendered ≤30 s clips).
    static let systemSounds: URL = directory(URL.libraryDirectory.appending(path: "Sounds"))

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
