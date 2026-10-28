import Foundation
import Observation

@Observable
final class SoundLibrary {
    static let shared = SoundLibrary()

    let system = SoundItem(id: SoundItem.systemID, name: "iPhone alarm", subtitle: "System sound",
                           kind: .system, fileName: nil, duration: 0)
    let builtIns = BuiltInTone.allCases.map(\.soundItem)
    private(set) var imported: [SoundItem] = []

    @ObservationIgnored private let indexURL = AppPaths.support.appending(path: "sounds.json")

    init() {
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([SoundItem].self, from: data) {
            imported = saved
        }
    }

    var all: [SoundItem] { [system] + builtIns + imported }

    func sound(withID id: String) -> SoundItem {
        all.first { $0.id == id } ?? builtIns[0]
    }

    func fileURL(for sound: SoundItem) -> URL? {
        sound.fileName.map { AppPaths.soundLibrary.appending(path: $0) }
    }

    func prepareBuiltIns() async {
        for tone in BuiltInTone.allCases {
            let url = AppPaths.soundLibrary.appending(path: tone.fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? await Task.detached { try ToneSynth.write(tone, to: url) }.value
        }
    }

    func add(_ sound: SoundItem) {
        imported.insert(sound, at: 0)
        save()
    }

    func rename(_ id: String, to name: String) {
        guard let index = imported.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        imported[index].name = name
        save()
    }

    func remove(_ id: String) {
        guard let index = imported.firstIndex(where: { $0.id == id }) else { return }
        if let url = fileURL(for: imported[index]) { try? FileManager.default.removeItem(at: url) }
        imported.remove(at: index)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(imported) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
