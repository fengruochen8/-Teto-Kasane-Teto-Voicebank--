import Foundation

struct MelodyNote: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Int
    var length: Int
    var pitch: Int
    var lyric = "ら"

    var end: Int { start + length }
}

struct MelodyProject: Codable, Equatable, Sendable {
    static let stepsPerBeat = 4
    static let stepsPerBar = stepsPerBeat * 4
    static let steps = stepsPerBar * 4
    static let pitches = 55...78
    static let tempos = 60...180

    var tempo = 112
    var notes: [MelodyNote] = []

    func canPlace(_ note: MelodyNote) -> Bool {
        Self.isInGrid(note) &&
            !notes.contains { $0.id != note.id && $0.start < note.end && note.start < $0.end }
    }

    private static func isInGrid(_ note: MelodyNote) -> Bool {
        note.start >= 0 && note.start < Self.steps &&
            note.length > 0 && note.length <= Self.steps - note.start &&
            Self.pitches.contains(note.pitch) && note.lyric.count <= 12
    }

    var isValid: Bool {
        Self.tempos.contains(tempo) &&
            notes.count <= Self.steps &&
            Set(notes.map(\.id)).count == notes.count &&
            notes.allSatisfy(Self.isInGrid) && notes.allSatisfy(canPlace)
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[pitch % 12])\(pitch / 12 - 1)"
    }

    static let example = MelodyProject(notes: [
        MelodyNote(start: 0, length: 4, pitch: 60),
        MelodyNote(start: 4, length: 4, pitch: 64),
        MelodyNote(start: 8, length: 6, pitch: 67),
        MelodyNote(start: 16, length: 8, pitch: 69),
        MelodyNote(start: 24, length: 4, pitch: 67),
        MelodyNote(start: 28, length: 4, pitch: 64),
        MelodyNote(start: 32, length: 6, pitch: 62),
        MelodyNote(start: 40, length: 8, pitch: 65),
        MelodyNote(start: 48, length: 4, pitch: 64),
        MelodyNote(start: 52, length: 4, pitch: 62),
        MelodyNote(start: 56, length: 8, pitch: 60)
    ])
}

enum StudioStorage {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MelodySketch", isDirectory: true)
    private static let projectURL = root.appendingPathComponent("Project.json")
    private static let bankURL = root.appendingPathComponent("ActiveVoicebank.txt")

    static func loadProject() -> MelodyProject {
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONDecoder().decode(MelodyProject.self, from: data),
              project.isValid else { return .example }
        return project
    }

    static func save(_ project: MelodyProject) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: projectURL, options: .atomic)
    }

    static func bankDirectory(for id: UUID) -> URL {
        root.appendingPathComponent("Voicebanks", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func loadBank() -> Voicebank? {
        guard let name = try? String(contentsOf: bankURL, encoding: .utf8),
              let id = UUID(uuidString: name),
              let data = try? Data(contentsOf: bankDirectory(for: id).appendingPathComponent("Samples.json")),
              let samples = try? JSONDecoder().decode([String: VoiceSample].self, from: data),
              samples["ら"] != nil else { return nil }
        return Voicebank(id: id, samples: samples)
    }

    static func activate(_ bank: Voicebank) throws {
        try Data(bank.id.uuidString.utf8).write(to: bankURL, options: .atomic)
    }
}
