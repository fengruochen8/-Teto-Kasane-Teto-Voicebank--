import Foundation

struct MelodyNote: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Int
    var length: Int
    var pitch: Int
    var lyric = "ら"

    var end: Int { start + length }
}

struct MelodyTrack: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var notes: [MelodyNote] = []
    var isMuted = false
    var isSolo = false

    func canPlace(_ note: MelodyNote) -> Bool {
        MelodyProject.isInGrid(note) && !notes.contains { $0.id != note.id && $0.start < note.end && note.start < $0.end }
    }

    func newNote(at step: Int, pitch: Int, length: Int = MelodyProject.stepsPerBeat) -> MelodyNote? {
        guard (0..<MelodyProject.steps).contains(step) else { return nil }
        let nextStart = notes.lazy.map(\.start).filter { $0 >= step }.min() ?? MelodyProject.steps
        let note = MelodyNote(start: step, length: min(length, nextStart - step), pitch: pitch)
        return canPlace(note) ? note : nil
    }

    func noteForKeyboard(at step: Int, pitch: Int) -> MelodyNote? {
        if var note = notes.first(where: { $0.start == step }) {
            note.pitch = pitch
            return canPlace(note) ? note : nil
        }
        return newNote(at: step, pitch: pitch)
    }

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == trimmed, !name.isEmpty, name.count <= 32,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              notes.count <= MelodyProject.steps, Set(notes.map(\.id)).count == notes.count,
              notes.allSatisfy(MelodyProject.isInGrid) else { return false }
        let orderedNotes = notes.sorted { $0.start < $1.start }
        return zip(orderedNotes, orderedNotes.dropFirst()).allSatisfy { earlier, later in
            earlier.end <= later.start
        }
    }
}

struct MelodyProject: Codable, Equatable, Sendable {
    static let stepsPerBeat = 4
    static let stepsPerBar = stepsPerBeat * 4
    static let steps = stepsPerBar * 4
    static let pitches = 55...78
    static let tempos = 60...180
    static let maxTracks = 8

    var tempo: Int
    var tracks: [MelodyTrack]

    init(tempo: Int = 112, notes: [MelodyNote] = []) {
        self.tempo = tempo
        self.tracks = [MelodyTrack(name: "主唱", notes: notes)]
    }

    init(tempo: Int = 112, tracks: [MelodyTrack]) {
        self.tempo = tempo
        self.tracks = tracks
    }

    var noteCount: Int { tracks.reduce(0) { $0 + $1.notes.count } }

    var audibleTracks: [MelodyTrack] {
        let hasSolo = tracks.contains(where: \.isSolo)
        return tracks.filter { !$0.isMuted && (!hasSolo || $0.isSolo) }
    }

    fileprivate static func isInGrid(_ note: MelodyNote) -> Bool {
        note.start >= 0 && note.start < Self.steps && note.length > 0 && note.length <= Self.steps - note.start &&
            Self.pitches.contains(note.pitch) && note.lyric.count <= 12
    }

    var isValid: Bool {
        Self.tempos.contains(tempo) && (1...Self.maxTracks).contains(tracks.count) &&
            Set(tracks.map(\.id)).count == tracks.count && tracks.allSatisfy(\.isValid)
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

    private enum CodingKeys: String, CodingKey { case tempo, tracks, notes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tempo = try container.decode(Int.self, forKey: .tempo)
        if let tracks = try container.decodeIfPresent([MelodyTrack].self, forKey: .tracks) {
            self.init(tempo: tempo, tracks: tracks)
        } else {
            self.init(tempo: tempo, notes: try container.decode([MelodyNote].self, forKey: .notes))
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .tracks, in: container,
                                                   debugDescription: "Invalid melody project")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tempo, forKey: .tempo)
        try container.encode(tracks, forKey: .tracks)
    }
}

enum StudioStorage {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MelodySketch", isDirectory: true)
    private static let bankURL = root.appendingPathComponent("ActiveVoicebank.txt")

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
