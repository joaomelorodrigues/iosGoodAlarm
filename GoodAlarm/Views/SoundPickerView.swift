import MediaPlayer
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SoundPickerView: View {
    @Binding var selection: String
    @Environment(AlarmStore.self) private var store
    @State private var player = FadingPlayer()
    @State private var showFiles = false
    @State private var showMusic = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importCount = 0
    @State private var importError: String?
    @State private var renaming: SoundItem?
    @State private var renameText = ""

    private var library: SoundLibrary { store.library }

    var body: some View {
        List {
            Section {
                Button { openMusicLibrary() } label: {
                    Label("Music library", systemImage: "music.note.list")
                }
                PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                    Label("Sound from a video in Photos", systemImage: "photo.on.rectangle.angled")
                }
                Button { showFiles = true } label: {
                    Label("Files (MP3, M4A, WAV, FLAC, video…)", systemImage: "folder")
                }
            } header: {
                Text("Add your own")
            } footer: {
                Text("Songs you own and any audio or video file work. Apple Music streaming tracks are DRM-locked by Apple and can't be used by any alarm app.")
            }

            if !library.imported.isEmpty {
                Section("My sounds") {
                    ForEach(library.imported) { sound in
                        row(sound)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { remove(sound) }
                                Button("Rename", systemImage: "pencil") { beginRename(sound) }
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { beginRename(sound) }
                                Button("Delete", systemImage: "trash", role: .destructive) { remove(sound) }
                            }
                    }
                }
            }

            Section("Built-in") {
                ForEach(library.builtIns) { row($0) }
            }

            Section {
                row(library.system)
            } footer: {
                Text("The standard iPhone alarm. Volume, fade and start position don't apply to it.")
            }
        }
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if importCount > 0 {
                ProgressView("Importing…")
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio, .movie, .audiovisualContent],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .sheet(isPresented: $showMusic) {
            MusicLibraryPicker { items in importSongs(items) }
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) {
            if let photoItem { importVideo(photoItem) }
        }
        .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert("Rename sound", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming { library.rename(renaming.id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { player.stop() }
    }

    private func row(_ sound: SoundItem) -> some View {
        let isSelected = selection == sound.id
        let isPlaying = player.playingURL != nil && player.playingURL == library.fileURL(for: sound)
        return Button {
            selection = sound.id
            togglePreview(sound, forcePlay: true)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.name).foregroundStyle(.primary).lineLimit(1)
                    Text(sound.duration > 0 ? "\(sound.subtitle) · \(TimeFormat.duration(sound.duration))" : sound.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if sound.isFileBased {
                    Button {
                        togglePreview(sound, forcePlay: false)
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPlaying ? "Stop preview" : "Preview")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview

    private func togglePreview(_ sound: SoundItem, forcePlay: Bool) {
        guard let url = library.fileURL(for: sound) else {
            player.stop()
            return
        }
        if player.playingURL == url && !forcePlay {
            player.stop()
            return
        }
        FadingPlayer.activatePlaybackSession()
        try? player.play(url: url, amplitude: 0.6)
    }

    // MARK: - Import

    private func openMusicLibrary() {
        MPMediaLibrary.requestAuthorization { status in
            Task { @MainActor in
                if status == .authorized {
                    showMusic = true
                } else {
                    importError = "Allow access to your music library in Settings › Good Alarm."
                }
            }
        }
    }

    private func importSongs(_ songs: [(url: URL?, title: String, artist: String)]) {
        for song in songs {
            guard let url = song.url else {
                importError = SoundImporter.ImportError.protectedContent.errorDescription
                continue
            }
            runImport { try await SoundImporter.importSound(from: url, name: song.title, subtitle: song.artist) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            runImport {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await SoundImporter.importSound(from: url, name: url.deletingPathExtension().lastPathComponent,
                                                           subtitle: "From Files")
            }
        }
    }

    private func importVideo(_ item: PhotosPickerItem) {
        runImport {
            defer { photoItem = nil }
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw SoundImporter.ImportError.noAudioTrack
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let name = "Video sound \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            return try await SoundImporter.importSound(from: movie.url, name: name, subtitle: "From Photos")
        }
    }

    private func runImport(_ work: @escaping () async throws -> SoundItem) {
        importCount += 1
        Task {
            defer { importCount -= 1 }
            do {
                let sound = try await work()
                library.add(sound)
                selection = sound.id
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func beginRename(_ sound: SoundItem) {
        renameText = sound.name
        renaming = sound
    }

    private func remove(_ sound: SoundItem) {
        if player.playingURL == library.fileURL(for: sound) { player.stop() }
        if selection == sound.id { selection = SoundItem.defaultID }
        library.remove(sound.id)
        store.soundRemoved(sound.id)
    }
}

/// A video handed over by the Photos picker, copied somewhere we can read it.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

struct MusicLibraryPicker: UIViewControllerRepresentable {
    let onPick: ([(url: URL?, title: String, artist: String)]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = true
        picker.showsCloudItems = false
        picker.showsItemsWithProtectedAssets = false
        picker.prompt = "Pick songs to wake up to"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        private let parent: MusicLibraryPicker

        init(_ parent: MusicLibraryPicker) { self.parent = parent }

        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            parent.onPick(mediaItemCollection.items.map {
                (url: $0.assetURL, title: $0.title ?? "Song", artist: $0.artist ?? "Music library")
            })
            parent.dismiss()
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            parent.dismiss()
        }
    }
}
