import AVFoundation
import UniformTypeIdentifiers

/// Copies any audio file, song or video soundtrack into the app's sound library.
nonisolated enum SoundImporter {
    enum ImportError: LocalizedError {
        case noAudioTrack
        case protectedContent
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "That file doesn't contain any audio."
            case .protectedContent: "This song is DRM-protected (Apple Music streaming). iOS doesn't let any app use it. Songs you bought or synced, and your own files, work."
            case .exportFailed: "The audio couldn't be converted."
            }
        }
    }

    /// `source` can be a file URL or an `ipod-library://` URL from the music library.
    @concurrent
    static func importSound(from source: URL, name: String, subtitle: String) async throws -> SoundItem {
        let id = UUID().uuidString
        var destination: URL
        if source.isFileURL, isDirectlyPlayable(source) {
            destination = AppPaths.soundLibrary.appending(path: "\(id).\(source.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            destination = AppPaths.soundLibrary.appending(path: "\(id).m4a")
            try await exportAudio(from: AVURLAsset(url: source), to: destination)
        }
        let file = try AVAudioFile(forReading: destination)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return SoundItem(id: id, name: name, subtitle: subtitle, kind: .imported,
                         fileName: destination.lastPathComponent, duration: duration)
    }

    private static func isDirectlyPlayable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { return false }
        return (try? AVAudioFile(forReading: url)) != nil
    }

    private static func exportAudio(from asset: AVURLAsset, to destination: URL) async throws {
        if try await asset.load(.hasProtectedContent) { throw ImportError.protectedContent }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ImportError.noAudioTrack }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.exportFailed
        }
        try await session.export(to: destination, as: .m4a)
    }
}
