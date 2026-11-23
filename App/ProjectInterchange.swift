import Foundation
import Yams

/// File interchange for notation data. Audio, voicebanks, expression curves and automation stay in
/// their originating application because the current project model has no equivalent representation.
enum ProjectInterchange: String, CaseIterable, Sendable {
    case midi
    case ust
    case ustx

    static let ticksPerQuarter = 480
    private static let ticksPerStep = ticksPerQuarter / MelodyProject.stepsPerBeat
    private static let maximumFileSize = 8 * 1_024 * 1_024
    private static let maximumImportedNotes = MelodyProject.maxTracks * MelodyProject.maxNotesPerTrack

    struct ImportResult: Sendable {
        let melody: MelodyProject
        let warnings: [String]
    }

    var fileExtension: String {
        switch self {
        case .midi: return "mid"
        case .ust, .ustx: return rawValue
        }
    }

    var documentTypeName: String {
        switch self {
        case .midi: return "MIDI"
        case .ust: return "UTAU Sequence Text"
        case .ustx: return "OpenUtau Project"
        }
    }

    func decode(_ data: Data) throws -> ImportResult {
        guard !data.isEmpty, data.count <= Self.maximumFileSize else { throw InterchangeError.fileTooLarge }
        switch self {
        case .midi: return try Self.decodeMIDI(data)
        case .ust: return try Self.decodeUST(data)
        case .ustx: return try Self.decodeUSTX(data)
        }
    }

    func encode(_ melody: MelodyProject, title: String, selectedTrackID: UUID?) throws -> Data {
        guard melody.isValid else { throw InterchangeError.invalidProject }
        switch self {
        case .midi: return try Self.encodeMIDI(melody, title: title)
        case .ust: return try Self.encodeUST(melody, title: title, selectedTrackID: selectedTrackID)
        case .ustx: return try Self.encodeUSTX(melody, title: title)
        }
    }
}

extension ProjectInterchange {
    private static func encodeMIDI(_ melody: MelodyProject, title: String) throws -> Data {
        var output = Data("MThd".utf8)
        output.append(bigEndian(UInt32(6)))
        output.append(bigEndian(UInt16(1)))
        output.append(bigEndian(UInt16(melody.tracks.count + 1)))
        output.append(bigEndian(UInt16(ticksPerQuarter)))

        var conductor = [MIDIEvent(time: 0, bytes: metaEvent(0x03, text: safeText(title)))]
        let microsecondsPerQuarter = Int((60_000_000.0 / Double(melody.tempo)).rounded())
        conductor.append(MIDIEvent(time: 0, bytes: [0xFF, 0x51, 0x03,
                                                       UInt8((microsecondsPerQuarter >> 16) & 0xFF),
                                                       UInt8((microsecondsPerQuarter >> 8) & 0xFF),
                                                       UInt8(microsecondsPerQuarter & 0xFF)]))
        output.append(midiTrackData(conductor))

        for (trackIndex, track) in melody.tracks.enumerated() {
            var events = [MIDIEvent(time: 0, bytes: metaEvent(0x03, text: safeText(track.name)))]
            for note in track.notes.sorted(by: noteOrder) {
                let start = ticks(fromStep: note.start)
                let end = ticks(fromStep: note.end)
                let lyric = safeText(note.lyric)
                events.append(MIDIEvent(time: start, bytes: metaEvent(0x05, text: lyric)))
                let channel = UInt8(trackIndex % 16)
                events.append(MIDIEvent(time: start, bytes: [0x90 | channel, UInt8(note.pitch), 100]))
                events.append(MIDIEvent(time: end, bytes: [0x80 | channel, UInt8(note.pitch), 0]))
            }
            output.append(midiTrackData(events, endTime: ticks(fromStep: melody.steps)))
        }
        return output
    }

    private static func decodeMIDI(_ data: Data) throws -> ImportResult {
        var reader = ByteReader(data)
        guard try reader.readASCII(count: 4) == "MThd", try reader.readUInt32() == 6 else {
            throw InterchangeError.unsupportedMIDI
        }
        let format = try reader.readUInt16()
        let trackCount = Int(try reader.readUInt16())
        let rawDivision = try reader.readUInt16()
        let division = Int(rawDivision)
        guard rawDivision & 0x8000 == 0, format == 0 || format == 1,
              trackCount > 0, trackCount <= 256, division > 0 else {
            throw InterchangeError.unsupportedMIDI
        }

        var rawTracks: [ImportedTrack] = []
        var tempo = 120
        var foundTempo = false
        var warnings: [String] = []
        var timelineEnd = 0
        for _ in 0..<trackCount {
            guard try reader.readASCII(count: 4) == "MTrk" else { throw InterchangeError.unsupportedMIDI }
            let length = Int(try reader.readUInt32())
            let bytes = try reader.readData(count: length)
            let parsed = try parseMIDITrack(bytes, division: division)
            timelineEnd = max(timelineEnd, parsed.endTime)
            if let candidate = parsed.tempo, !foundTempo {
                tempo = candidate
                foundTempo = true
            } else if parsed.hasTempoChange { warnings.append("MIDI 中的后续速度变化已按首个速度导入。") }
            if parsed.hasNonFourFourTimeSignature { warnings.append("MIDI 的非4/4拍号已按4/4导入。") }
            if !parsed.notes.isEmpty { rawTracks.append(ImportedTrack(name: parsed.name, notes: parsed.notes)) }
        }
        guard !rawTracks.isEmpty else { throw InterchangeError.noNotes }
        return try buildResult(tempo: tempo, importedTracks: rawTracks, warnings: warnings, timelineEndTicks: timelineEnd)
    }

    private static func parseMIDITrack(_ bytes: Data, division: Int) throws -> ParsedMIDITrack {
        var reader = ByteReader(bytes)
        var absolute = 0
        var runningStatus: UInt8?
        var name = "MIDI 音轨"
        var lyrics: [(time: Int, lyric: String)] = []
        var active: [MIDIKey: [Int]] = [:]
        var notes: [TimedNote] = []
        var firstTempo: Int?
        var tempoCount = 0
        var hasNonFourFourTimeSignature = false

        while !reader.isAtEnd {
            let delta = try reader.readVariableLength()
            guard absolute <= Int.max - delta else { throw InterchangeError.unsupportedMIDI }
            absolute += delta
            let first = try reader.readByte()
            let status: UInt8
            let firstData: UInt8?
            if first < 0x80 {
                guard let runningStatus else { throw InterchangeError.unsupportedMIDI }
                status = runningStatus
                firstData = first
            } else {
                status = first
                firstData = nil
                if status < 0xF0 { runningStatus = status }
            }

            if status == 0xFF {
                let type = try reader.readByte()
                let payload = try reader.readData(count: try reader.readVariableLength())
                runningStatus = nil
                if type == 0x2F { break }
                if type == 0x03, let candidate = String(data: payload, encoding: .utf8), !candidate.isEmpty { name = candidate }
                if type == 0x05 || type == 0x01, let lyric = String(data: payload, encoding: .utf8), !lyric.isEmpty {
                    lyrics.append((absolute, lyric))
                }
                if type == 0x51, payload.count == 3 {
                    let microseconds = Int(payload[payload.startIndex]) << 16 | Int(payload[payload.startIndex + 1]) << 8 | Int(payload[payload.startIndex + 2])
                    if microseconds > 0 {
                        tempoCount += 1
                        if firstTempo == nil { firstTempo = boundedInteger(60_000_000.0 / Double(microseconds)) }
                    }
                }
                if type == 0x58, payload.count >= 2, (payload[0] != 4 || payload[1] != 2) {
                    hasNonFourFourTimeSignature = true
                }
                continue
            }
            if status == 0xF0 || status == 0xF7 {
                runningStatus = nil
                _ = try reader.readData(count: try reader.readVariableLength())
                continue
            }

            let command = status & 0xF0
            let channel = status & 0x0F
            let firstValue = try firstData ?? reader.readByte()
            let secondValue: UInt8
            switch command {
            case 0xC0, 0xD0:
                continue
            case 0x80, 0x90, 0xA0, 0xB0, 0xE0:
                secondValue = try reader.readByte()
            default:
                throw InterchangeError.unsupportedMIDI
            }
            guard command == 0x80 || command == 0x90 else { continue }
            let key = MIDIKey(channel: channel, pitch: firstValue)
            if command == 0x90 && secondValue > 0 {
                active[key, default: []].append(absolute)
            } else if let start = active[key]?.popLast(), absolute > start {
                guard notes.count < maximumImportedNotes else { throw InterchangeError.tooManyNotes }
                notes.append(TimedNote(start: start, end: absolute, pitch: Int(firstValue), lyric: lyric(at: start, from: lyrics)))
            }
        }
        return ParsedMIDITrack(name: sanitizedName(name, fallback: "MIDI 音轨"), notes: notes,
                               tempo: firstTempo, hasTempoChange: tempoCount > 1,
                               hasNonFourFourTimeSignature: hasNonFourFourTimeSignature, endTime: absolute)
    }

    private static func midiTrackData(_ events: [MIDIEvent], endTime: Int? = nil) -> Data {
        var data = Data()
        var previous = 0
        let ordered = events.sorted { left, right in
            left.time == right.time ? left.sortRank < right.sortRank : left.time < right.time
        }
        for event in ordered {
            data.append(contentsOf: variableLength(event.time - previous))
            data.append(contentsOf: event.bytes)
            previous = event.time
        }
        data.append(contentsOf: variableLength(max(0, (endTime ?? previous) - previous)))
        data.append(contentsOf: [0xFF, 0x2F, 0x00])
        var chunk = Data("MTrk".utf8)
        chunk.append(bigEndian(UInt32(data.count)))
        chunk.append(data)
        return chunk
    }
}

extension ProjectInterchange {
    private static func encodeUST(_ melody: MelodyProject, title: String, selectedTrackID: UUID?) throws -> Data {
        let track = melody.tracks.first { $0.id == selectedTrackID } ?? melody.tracks.first
        guard let track else { throw InterchangeError.noNotes }
        var rows = ["[#VERSION]", "UST Version1.2", "", "[#SETTING]",
                    "Tempo=\(melody.tempo)", "ProjectName=\(iniText(title))", "Tracks=1", "Charset=Shift_JIS", ""]
        var cursor = 0
        var index = 0
        for note in track.notes.sorted(by: noteOrder) {
            if note.start > cursor {
                rows += ustNote(index: index, length: note.start - cursor, pitch: 60, lyric: "R")
                index += 1
            }
            rows += ustNote(index: index, length: note.length, pitch: note.pitch, lyric: note.lyric)
            index += 1
            cursor = note.end
        }
        if cursor < melody.steps { rows += ustNote(index: index, length: melody.steps - cursor, pitch: 60, lyric: "R") }
        rows += ["[#TRACKEND]", ""]
        let shiftJISText = rows.joined(separator: "\r\n")
        if let shiftJIS = shiftJISText.data(using: .shiftJIS) { return shiftJIS }
        // Apple Foundation cannot encode every modern Unicode scalar as Shift-JIS.
        // OpenUtau accepts this UTF-8 fallback, while older UTAU builds may require
        // the user to replace unrepresentable lyrics with Shift-JIS-compatible text.
        let utf8Text = shiftJISText.replacingOccurrences(of: "Charset=Shift_JIS", with: "Charset=UTF-8")
        return Data(utf8Text.utf8)
    }

    private static func decodeUST(_ data: Data) throws -> ImportResult {
        let text = try decodeUSTText(data)
        let blocks = iniBlocks(text)
        guard let settings = blocks.first(where: { $0.header.uppercased() == "#SETTING" }) else { throw InterchangeError.unsupportedUST }
        let tempo = boundedInteger(Double(settings.values["Tempo"] ?? "120") ?? 120) ?? 120
        let title = sanitizedName(settings.values["ProjectName"] ?? "UTAU 音轨", fallback: "UTAU 音轨")
        var cursor = 0
        var notes: [TimedNote] = []
        var warnings: [String] = []
        for block in blocks where block.header.hasPrefix("#") && block.header != "#VERSION" && block.header != "#SETTING" && block.header != "#TRACKEND" {
            guard let length = Int(block.values["Length"] ?? ""), length > 0,
                  cursor <= Int.max - length else { throw InterchangeError.unsupportedUST }
            let lyric = block.values["Lyric"] ?? "R"
            if let noteTempo = block.values["Tempo"], let noteTempoValue = boundedInteger(Double(noteTempo)), noteTempoValue != tempo {
                warnings.append("UST 的逐音符速度变化已按工程速度导入。")
            }
            if lyric.lowercased() != "r" {
                guard let pitch = Int(block.values["NoteNum"] ?? "") else { throw InterchangeError.unsupportedUST }
                guard notes.count < maximumImportedNotes else { throw InterchangeError.tooManyNotes }
                notes.append(TimedNote(start: cursor, end: cursor + length, pitch: pitch, lyric: lyric))
            }
            cursor += length
        }
        guard !notes.isEmpty else { throw InterchangeError.noNotes }
        return try buildResult(tempo: tempo, importedTracks: [ImportedTrack(name: title, notes: notes)], warnings: warnings, timelineEndTicks: cursor)
    }

    private static func ustNote(index: Int, length: Int, pitch: Int, lyric: String) -> [String] {
        ["[#\(String(format: "%04d", index))]", "Length=\(ticks(fromStep: length))", "Lyric=\(iniText(lyric))", "NoteNum=\(pitch)", ""]
    }

    private static func decodeUSTText(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .shiftJIS) { return text }
        throw InterchangeError.unsupportedUST
    }
}

extension ProjectInterchange {
    private static func encodeUSTX(_ melody: MelodyProject, title: String) throws -> Data {
        let tracks: [[String: Any]] = melody.tracks.map { track in
            ["track_name": track.name, "mute": track.isMuted, "solo": track.isSolo,
             "volume": 20 * log10(max(track.volume, 0.000_001)), "track_color": "#D65F8D"]
        }
        let parts: [[String: Any]] = melody.tracks.enumerated().map { index, track in
            let notes: [[String: Any]] = track.notes.sorted(by: noteOrder).map { note in
                ["position": ticks(fromStep: note.start), "duration": ticks(fromStep: note.length),
                 "tone": note.pitch, "lyric": note.expression.slur ? "+" : note.lyric]
            }
            return ["name": track.name, "track_no": index, "position": 0,
                    "duration": ticks(fromStep: melody.steps), "notes": notes]
        }
        let document: [String: Any] = [
            "ustx_version": "0.6", "name": safeText(title), "resolution": ticksPerQuarter, "key": 0,
            "time_signatures": [["bar_position": 0, "beat_per_bar": 4, "beat_unit": 4]],
            "tempos": [["position": 0, "bpm": Double(melody.tempo)]], "tracks": tracks, "voice_parts": parts,
        ]
        guard let result = try Yams.dump(object: document).data(using: .utf8) else {
            throw InterchangeError.invalidProject
        }
        return result
    }

    private static func decodeUSTX(_ data: Data) throws -> ImportResult {
        guard let text = String(data: data, encoding: .utf8), let root = try Yams.load(yaml: text) as? [String: Any] else {
            throw InterchangeError.unsupportedUSTX
        }
        guard let resolution = boundedInteger(number(root["resolution"]) ?? Double(ticksPerQuarter), minimum: 1, maximum: 1_000_000) else {
            throw InterchangeError.unsupportedUSTX
        }
        let rawTracks = root["tracks"] as? [[String: Any]] ?? []
        let voiceParts = root["voice_parts"] as? [[String: Any]] ?? []
        guard !voiceParts.isEmpty else { throw InterchangeError.noNotes }
        var warnings: [String] = []
        let tempos = root["tempos"] as? [[String: Any]] ?? []
        let tempo = boundedInteger(number(tempos.first?["bpm"]) ?? 120) ?? 120
        if tempos.count > 1 { warnings.append("USTX 的后续速度变化已按首个速度导入。") }
        let signatures = (root["time_signatures"] ?? root["time_signature"]) as? [[String: Any]] ?? []
        if signatures.count > 1 || signatures.first.map({ number($0["beat_per_bar"]) != 4 || number($0["beat_unit"]) != 4 }) == true {
            warnings.append("USTX 的拍号变化已按 4/4 导入。")
        }
        if !(root["wave_parts"] as? [Any] ?? []).isEmpty { warnings.append("USTX 的伴奏音频片段未导入。") }

        var importedByIndex: [Int: ImportedTrack] = [:]
        var timelineEnd = 0
        for part in voiceParts {
            guard let trackIndex = boundedInteger(number(part["track_no"]) ?? 0, minimum: 0, maximum: MelodyProject.maxTracks * 16) else { continue }
            let sourceTrack = trackIndex < rawTracks.count ? rawTracks[trackIndex] : [:]
            let name = sanitizedName((sourceTrack["track_name"] as? String) ?? (part["name"] as? String) ?? "OpenUtau 音轨", fallback: "OpenUtau 音轨")
            guard let partPosition = boundedInteger(number(part["position"]) ?? 0, minimum: 0),
                  let partDuration = boundedInteger(number(part["duration"]) ?? 0, minimum: 0),
                  partPosition <= Int.max - partDuration else { throw InterchangeError.unsupportedUSTX }
            timelineEnd = max(timelineEnd, partPosition + max(0, partDuration))
            let rawNotes = part["notes"] as? [[String: Any]] ?? []
            guard rawNotes.count <= maximumImportedNotes else { throw InterchangeError.tooManyNotes }
            let notes = rawNotes.compactMap { value -> TimedNote? in
                guard let position = boundedInteger(number(value["position"]), minimum: 0),
                      let duration = boundedInteger(number(value["duration"]), minimum: 1),
                      let tone = boundedInteger(number(value["tone"])),
                      position <= Int.max - duration, partPosition <= Int.max - (position + duration) else { return nil }
                return TimedNote(start: partPosition + position,
                                 end: partPosition + position + duration,
                                 pitch: tone, lyric: value["lyric"] as? String ?? "ら")
            }
            let sourceVolume = number(sourceTrack["volume"]) ?? 0
            let volume = sourceVolume.isFinite ? min(2, max(0, pow(10, sourceVolume / 20))) : 1
            guard !notes.isEmpty else { continue }
            let muted = sourceTrack["mute"] as? Bool ?? false
            let solo = sourceTrack["solo"] as? Bool ?? false
            if let existing = importedByIndex[trackIndex] {
                importedByIndex[trackIndex] = ImportedTrack(name: existing.name, notes: existing.notes + notes,
                                                            muted: existing.muted || muted, solo: existing.solo || solo,
                                                            volume: existing.volume)
            } else {
                importedByIndex[trackIndex] = ImportedTrack(name: name, notes: notes, muted: muted, solo: solo, volume: volume)
            }
        }
        let imported = importedByIndex.keys.sorted().compactMap { importedByIndex[$0] }
        guard !imported.isEmpty else { throw InterchangeError.noNotes }
        if voiceParts.contains(where: { ($0["curves"] as? [Any])?.isEmpty == false || ($0["notes"] as? [[String: Any]])?.contains(where: { $0["pitch"] != nil || $0["vibrato"] != nil || $0["phoneme_overrides"] != nil }) == true }) {
            warnings.append("USTX 的音高曲线、颤音、音素时序和表情参数未导入。")
        }
        return try buildResult(tempo: tempo, importedTracks: imported, warnings: warnings,
                               resolution: resolution, timelineEndTicks: timelineEnd)
    }
}

extension ProjectInterchange {
    private static func buildResult(tempo rawTempo: Int, importedTracks: [ImportedTrack], warnings initialWarnings: [String], resolution: Int = ticksPerQuarter, timelineEndTicks: Int? = nil) throws -> ImportResult {
        var warnings = initialWarnings
        let tempo = min(MelodyProject.tempos.upperBound, max(MelodyProject.tempos.lowerBound, rawTempo))
        if tempo != rawTempo { warnings.append("速度已限制在 \(MelodyProject.tempos.lowerBound)–\(MelodyProject.tempos.upperBound) BPM。") }
        var tracks: [MelodyTrack] = []
        var furthestStep = 0
        for source in importedTracks {
            let converted = source.notes.compactMap { value -> MelodyNote? in
                let start = steps(fromTicks: value.start, resolution: resolution)
                let end = steps(fromTicks: value.end, resolution: resolution)
                guard end > start, start >= 0, MelodyProject.pitches.contains(value.pitch) else {
                    warnings.append("超出可编辑范围的音符已跳过。")
                    return nil
                }
                return MelodyNote(start: start, length: end - start, pitch: value.pitch, lyric: String(value.lyric.prefix(12)))
            }.sorted(by: noteOrder)
            guard !converted.isEmpty else { continue }
            let lanes = splitMonophonic(converted)
            if lanes.count > 1 { warnings.append("「\(source.name)」中的重叠音符已拆成 \(lanes.count) 条音轨。") }
            for (index, lane) in lanes.enumerated() {
                guard tracks.count < MelodyProject.maxTracks else {
                    warnings.append("超过 \(MelodyProject.maxTracks) 条音轨的内容未导入。")
                    break
                }
                var limited = Array(lane.prefix(MelodyProject.maxNotesPerTrack))
                for index in limited.indices where limited[index].lyric == "+" {
                    if index > 0, limited[index - 1].end == limited[index].start,
                       limited[index - 1].lyric != "っ" {
                        limited[index].expression.slur = true
                    } else {
                        warnings.append("未与前一音符相接的连音已使用默认假名。")
                    }
                    limited[index].lyric = "ら"
                }
                if lane.count > limited.count { warnings.append("「\(source.name)」超过 \(MelodyProject.maxNotesPerTrack) 个音符，后续音符未导入。") }
                let name = lanes.count == 1 ? source.name : "\(source.name) \(index + 1)"
                tracks.append(MelodyTrack(name: sanitizedName(name, fallback: "导入音轨"), notes: limited,
                                          isMuted: source.muted, isSolo: source.solo, volume: source.volume))
                furthestStep = max(furthestStep, limited.map(\.end).max() ?? 0)
            }
        }
        guard !tracks.isEmpty else { throw InterchangeError.noNotes }
        if let timelineEndTicks {
            furthestStep = max(furthestStep, steps(fromTicks: timelineEndTicks, resolution: resolution))
        }
        let bars = max(1, Int(ceil(Double(furthestStep) / Double(MelodyProject.stepsPerBar))))
        let barCount = min(MelodyProject.maxBars, bars)
        if bars != barCount { warnings.append("超出 \(MelodyProject.maxBars) 小节的内容未导入。") }
        let clippedTracks = tracks.map { track -> MelodyTrack in
            var copy = track
            copy.notes.removeAll { $0.end > barCount * MelodyProject.stepsPerBar }
            return copy
        }.filter { !$0.notes.isEmpty }
        guard !clippedTracks.isEmpty else { throw InterchangeError.noNotes }
        return ImportResult(melody: MelodyProject(tempo: tempo, tracks: clippedTracks, barCount: barCount), warnings: unique(warnings))
    }

    private static func splitMonophonic(_ notes: [MelodyNote]) -> [[MelodyNote]] {
        var lanes: [[MelodyNote]] = []
        for note in notes {
            if let index = lanes.firstIndex(where: { ($0.last?.end ?? 0) <= note.start }) {
                lanes[index].append(note)
            } else {
                lanes.append([note])
            }
        }
        return lanes
    }

    private static func steps(fromTicks ticks: Int, resolution: Int) -> Int {
        let maximum = MelodyProject.stepsPerBar * MelodyProject.maxBars + 1
        let scaled = (Double(ticks) * Double(MelodyProject.stepsPerBeat) / Double(resolution)).rounded()
        return Int(max(0, min(Double(maximum), scaled)))
    }

    private static func ticks(fromStep step: Int) -> Int { step * ticksPerStep }

    private static func noteOrder(_ left: MelodyNote, _ right: MelodyNote) -> Bool {
        left.start == right.start ? left.pitch < right.pitch : left.start < right.start
    }

    private static func lyric(at time: Int, from lyrics: [(time: Int, lyric: String)]) -> String {
        guard let value = lyrics.last(where: { $0.time == time })?.lyric else { return "ら" }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned == "-" ? "ら" : String(cleaned.prefix(12))
    }

    private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in if !result.contains(value) { result.append(value) } }
    }

    private static func sanitizedName(_ name: String, fallback: String) -> String {
        let cleaned = name.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func safeText(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func iniText(_ value: String) -> String { safeText(value).replacingOccurrences(of: "=", with: "－") }
    private static func metaEvent(_ type: UInt8, text: String) -> [UInt8] {
        let bytes = Array(text.data(using: .utf8) ?? Data())
        return [0xFF, type] + variableLength(bytes.count) + bytes
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var result = value.bigEndian
        return Data(bytes: &result, count: MemoryLayout<T>.size)
    }

    private static func variableLength(_ value: Int) -> [UInt8] {
        var value = max(0, value)
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8((value & 0x7F) | 0x80), at: 0)
            value >>= 7
        }
        return bytes
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func boundedInteger(_ value: Double?, minimum: Int = Int.min, maximum: Int = Int.max) -> Int? {
        guard let value, value.isFinite, let integral = Int(exactly: value.rounded()),
              (minimum...maximum).contains(integral) else { return nil }
        return integral
    }

    private static func iniBlocks(_ text: String) -> [IniBlock] {
        var blocks: [IniBlock] = []
        var header: String?
        var values: [String: String] = [:]
        func finish() {
            if let header { blocks.append(IniBlock(header: header, values: values)) }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.first == "[", line.last == "]" {
                finish()
                header = String(line.dropFirst().dropLast())
                values = [:]
            } else if let separator = line.firstIndex(of: "="), header != nil {
                values[String(line[..<separator])] = String(line[line.index(after: separator)...])
            }
        }
        finish()
        return blocks
    }
}

private struct MIDIEvent {
    let time: Int
    let bytes: [UInt8]
    var sortRank: Int { bytes.first == 0xFF ? 0 : (bytes.first ?? 0) & 0xF0 == 0x80 ? 1 : 2 }
}

private struct MIDIKey: Hashable { let channel: UInt8; let pitch: UInt8 }
private struct TimedNote { let start: Int; let end: Int; let pitch: Int; let lyric: String }
private struct ImportedTrack {
    let name: String
    let notes: [TimedNote]
    var muted = false
    var solo = false
    var volume = 1.0
}
private struct ParsedMIDITrack { let name: String; let notes: [TimedNote]; let tempo: Int?; let hasTempoChange: Bool; let hasNonFourFourTimeSignature: Bool; let endTime: Int }
private struct IniBlock { let header: String; let values: [String: String] }

private struct ByteReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset >= data.count }
    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw ProjectInterchange.InterchangeError.truncated }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw ProjectInterchange.InterchangeError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func readASCII(count: Int) throws -> String { String(data: try readData(count: count), encoding: .ascii) ?? "" }
    mutating func readUInt16() throws -> UInt16 { UInt16(try readByte()) << 8 | UInt16(try readByte()) }
    mutating func readUInt32() throws -> UInt32 { UInt32(try readByte()) << 24 | UInt32(try readByte()) << 16 | UInt32(try readByte()) << 8 | UInt32(try readByte()) }
    mutating func readVariableLength() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try readByte()
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw ProjectInterchange.InterchangeError.unsupportedMIDI
    }
}

extension ProjectInterchange {
    enum InterchangeError: LocalizedError {
        case fileTooLarge, invalidProject, truncated, unsupportedMIDI, unsupportedUST, unsupportedUSTX, noNotes, tooManyNotes
        var errorDescription: String? {
            switch self {
            case .fileTooLarge: return "导入文件为空或超过 8MB 限制。"
            case .invalidProject: return "当前工程无法导出。"
            case .truncated: return "导入文件不完整。"
            case .unsupportedMIDI: return "这个 MIDI 文件使用了不支持的时间格式或事件。"
            case .unsupportedUST: return "这个 UST 文件缺少可识别的音符。"
            case .unsupportedUSTX: return "这个 USTX 文件格式无法读取。"
            case .noNotes: return "导入文件中没有可编辑的音符。"
            case .tooManyNotes: return "导入文件的音符数量超过支持范围。"
            }
        }
    }
}
