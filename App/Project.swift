import Foundation

struct PitchPoint: Codable, Equatable, Sendable {
    var position: Double
    var cents: Double
}

struct NoteExpression: Codable, Equatable, Sendable {
    var slur = false
    var transitionMilliseconds = 45
    var timingMilliseconds = 0
    var vibratoDepth = 0
    var vibratoRate = 5.5
    var pitchCurve: [PitchPoint] = []

    var isValid: Bool {
        (0...250).contains(transitionMilliseconds) && (-120...120).contains(timingMilliseconds) &&
            (0...150).contains(vibratoDepth) && (3...9).contains(vibratoRate) && pitchCurve.count <= 32 &&
            pitchCurve.allSatisfy { (0...1).contains($0.position) && (-1200...1200).contains($0.cents) } &&
            zip(pitchCurve, pitchCurve.dropFirst()).allSatisfy { $0.position < $1.position }
    }
}

struct MelodyNote: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Int
    var length: Int
    var pitch: Int
    var lyric = "ら"
    var expression = NoteExpression()

    var end: Int { start + length }
}

extension MelodyNote {
    private enum CodingKeys: String, CodingKey { case id, start, length, pitch, lyric, expression }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(Int.self, forKey: .start)
        length = try values.decode(Int.self, forKey: .length)
        pitch = try values.decode(Int.self, forKey: .pitch)
        lyric = try values.decode(String.self, forKey: .lyric)
        expression = try values.decodeIfPresent(NoteExpression.self, forKey: .expression) ?? NoteExpression()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(start, forKey: .start)
        try values.encode(length, forKey: .length)
        try values.encode(pitch, forKey: .pitch)
        try values.encode(lyric, forKey: .lyric)
        if expression != NoteExpression() { try values.encode(expression, forKey: .expression) }
    }
}

struct MelodyTrack: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var notes: [MelodyNote] = []
    var isMuted = false
    var isSolo = false
    var volume: Double = 1

    func canPlace(_ note: MelodyNote, limit: Int) -> Bool {
        MelodyProject.isInGrid(note, limit: limit) &&
            (notes.count < MelodyProject.maxNotesPerTrack || notes.contains { $0.id == note.id }) &&
            !notes.contains { $0.id != note.id && $0.start < note.end && note.start < $0.end }
    }

    func newNote(at step: Int, pitch: Int, length: Int = MelodyProject.stepsPerBeat, limit: Int) -> MelodyNote? {
        guard (0..<limit).contains(step) else { return nil }
        let nextStart = notes.lazy.map(\.start).filter { $0 >= step }.min() ?? limit
        let note = MelodyNote(start: step, length: min(length, nextStart - step), pitch: pitch)
        return canPlace(note, limit: limit) ? note : nil
    }

    func noteForKeyboard(at step: Int, pitch: Int, limit: Int) -> MelodyNote? {
        if var note = notes.first(where: { $0.start == step }) {
            note.pitch = pitch
            return canPlace(note, limit: limit) ? note : nil
        }
        return newNote(at: step, pitch: pitch, limit: limit)
    }

    func isValid(limit: Int) -> Bool {
        guard Self.isValidName(name), (0...2).contains(volume),
              notes.count <= MelodyProject.maxNotesPerTrack, Set(notes.map(\.id)).count == notes.count,
              notes.allSatisfy({ MelodyProject.isInGrid($0, limit: limit) }) else { return false }
        let ordered = notes.sorted { $0.start < $1.start }
        return zip(ordered, ordered.dropFirst()).allSatisfy { $0.end <= $1.start }
    }

    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == trimmed && !name.isEmpty && name.count <= 32 &&
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

extension MelodyTrack {
    private enum CodingKeys: String, CodingKey { case id, name, notes, isMuted, isSolo, volume }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        notes = try values.decode([MelodyNote].self, forKey: .notes)
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try values.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }
}

struct MeasureLoop: Codable, Equatable, Sendable {
    var firstBar: Int
    var endBar: Int

    var ticks: Range<Int> { (firstBar * MelodyProject.stepsPerBar)..<(endBar * MelodyProject.stepsPerBar) }
}

struct MelodyProject: Codable, Equatable, Sendable {
    static let stepsPerBeat = 480
    static let stepsPerBar = stepsPerBeat * 4
    static let maxBars = 128
    static let pitches = 0...127
    static let tempos = 20...300
    static let maxTracks = 8
    static let maxNotesPerTrack = 4096

    var tempo: Int
    var tracks: [MelodyTrack]
    var barCount: Int
    var loopRegion: MeasureLoop?

    init(tempo: Int = 112, notes: [MelodyNote] = [], barCount: Int = 4) {
        self.init(tempo: tempo, tracks: [MelodyTrack(name: "主唱", notes: notes)], barCount: barCount)
    }

    init(tempo: Int = 112, tracks: [MelodyTrack], barCount: Int = 4) {
        self.tempo = tempo
        self.tracks = tracks
        self.barCount = barCount
        self.loopRegion = nil
    }

    var steps: Int { barCount * Self.stepsPerBar }
    var noteCount: Int { tracks.reduce(0) { $0 + $1.notes.count } }

    var audibleTracks: [MelodyTrack] {
        let hasSolo = tracks.contains(where: \.isSolo)
        return tracks.filter { !$0.isMuted && (!hasSolo || $0.isSolo) }
    }

    static func isInGrid(_ note: MelodyNote, limit: Int) -> Bool {
        note.start >= 0 && note.start < limit && note.length > 0 && note.length <= limit - note.start &&
            pitches.contains(note.pitch) && note.lyric.count <= 12 && note.expression.isValid
    }

    var isValid: Bool {
        guard Self.tempos.contains(tempo), (1...Self.maxBars).contains(barCount),
              (1...Self.maxTracks).contains(tracks.count), Set(tracks.map(\.id)).count == tracks.count,
              tracks.allSatisfy({ $0.isValid(limit: steps) }) else { return false }
        if let loopRegion { return loopRegion.firstBar >= 0 && loopRegion.endBar <= barCount && loopRegion.firstBar < loopRegion.endBar }
        return true
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[pitch % 12])\(pitch / 12 - 1)"
    }

    private static let legacyTickScale = 120
    static let example: MelodyProject = {
        let phrase = [
            (0, 4, 60, "さ"), (4, 4, 64, "く"), (8, 6, 67, "ら"), (16, 8, 69, "が"),
            (24, 4, 67, "さ"), (28, 4, 64, "く"), (32, 6, 62, "そ"), (40, 8, 65, "ら"),
            (48, 4, 64, "の"), (52, 4, 62, "う"), (56, 8, 60, "た")
        ]
        var lead = MelodyTrack(name: "主唱")
        var harmony = MelodyTrack(name: "和声", volume: 0.48)
        for repeatIndex in 0..<4 {
            for (index, value) in phrase.enumerated() {
                let start = (repeatIndex * 64 + value.0) * legacyTickScale
                var note = MelodyNote(start: start, length: value.1 * legacyTickScale, pitch: value.2, lyric: value.3)
                if index == phrase.count - 1 { note.expression.vibratoDepth = 35 }
                lead.notes.append(note)
                if repeatIndex > 0 {
                    harmony.notes.append(MelodyNote(start: start, length: note.length, pitch: note.pitch - 3, lyric: note.lyric))
                }
            }
        }
        return MelodyProject(tracks: [lead, harmony], barCount: 16)
    }()

    private enum CodingKeys: String, CodingKey { case tempo, tracks, notes, ticksPerBeat, barCount, loopRegion }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let tempo = try values.decode(Int.self, forKey: .tempo)
        let invalid = DecodingError.dataCorruptedError(forKey: .tracks, in: values, debugDescription: "Invalid melody project")
        var tracks: [MelodyTrack]
        if let savedTracks = try values.decodeIfPresent([MelodyTrack].self, forKey: .tracks) {
            tracks = savedTracks
        } else {
            tracks = [MelodyTrack(name: "主唱", notes: try values.decode([MelodyNote].self, forKey: .notes))]
        }
        let resolution = try values.decodeIfPresent(Int.self, forKey: .ticksPerBeat)
        if resolution == nil {
            for track in tracks.indices {
                for noteIndex in tracks[track].notes.indices {
                    let note = tracks[track].notes[noteIndex]
                    guard (0..<64).contains(note.start), (1...64).contains(note.length) else { throw invalid }
                    tracks[track].notes[noteIndex].start *= Self.legacyTickScale
                    tracks[track].notes[noteIndex].length *= Self.legacyTickScale
                }
            }
        } else if resolution != Self.stepsPerBeat {
            throw invalid
        }
        self.init(tempo: tempo, tracks: tracks, barCount: try values.decodeIfPresent(Int.self, forKey: .barCount) ?? 4)
        loopRegion = try values.decodeIfPresent(MeasureLoop.self, forKey: .loopRegion)
        guard isValid else { throw invalid }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tempo, forKey: .tempo)
        try values.encode(tracks, forKey: .tracks)
        try values.encode(Self.stepsPerBeat, forKey: .ticksPerBeat)
        try values.encode(barCount, forKey: .barCount)
        try values.encodeIfPresent(loopRegion, forKey: .loopRegion)
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
