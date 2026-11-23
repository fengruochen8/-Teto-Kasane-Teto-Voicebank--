import AVFoundation
import Foundation

enum MelodyAudio {
    static let sampleRate = 44_100

    private struct PeriodKey: Hashable {
        let file: String
        let offset: Int
        let end: Int
        let consonant: Int
    }

    static func render(_ project: MelodyProject, bank: Voicebank, window: Range<Int>? = nil,
                       trackID: UUID? = nil) throws -> Data {
        guard project.noteCount > 0 else { throw StudioError.emptyMelody }
        let tracks = trackID.map { id in project.tracks.filter { $0.id == id } } ?? project.audibleTracks
        guard tracks.contains(where: { !$0.notes.isEmpty }) else {
            throw trackID == nil ? StudioError.silencedMelody : StudioError.emptyMelody
        }
        let region = window ?? 0..<project.steps
        guard region.lowerBound >= 0, region.upperBound <= project.steps, !region.isEmpty else {
            throw StudioError.playback
        }
        let framesPerTick = Double(sampleRate * 60) / Double(project.tempo * MelodyProject.stepsPerBeat)
        func frame(_ tick: Int) -> Int { Int((Double(tick) * framesPerTick).rounded()) }
        let startFrame = frame(region.lowerBound)
        let endFrame = frame(region.upperBound)
        var output = [Float](repeating: 0, count: endFrame - startFrame)
        var recordings: [String: [Float]] = [:]
        var cachedFrames = 0
        var periods: [PeriodKey: Int32] = [:]

        for track in tracks where track.volume > 0 {
            var previous: MelodyNote?
            for group in syllableGroups(in: track) {
                try Task.checkCancellation()
                guard let note = group.first, let last = group.last else { continue }
                defer { previous = last }
                let noteEnd = frame(last.end)
                let noteOnset = frame(note.start)
                guard noteEnd > startFrame, noteOnset - frames(for: 240) < endFrame else { continue }
                let normalized = Voicebank.kana(note.lyric)
                let lyric = normalized.isEmpty ? "ら" : normalized
                if lyric == "っ", bank.samples[lyric] == nil { continue }
                guard let sample = bank.samples[lyric] else { throw StudioError.missingLyric(note.lyric) }
                let lead = min(240, max(-120, sample.preutterance + Double(note.expression.timingMilliseconds)))
                let onset = min(noteEnd - 1, max(0, noteOnset - frames(for: lead)))
                let visibleStart = max(onset, startFrame)
                let visibleEnd = min(noteEnd, endFrame)
                guard visibleStart < visibleEnd else { continue }

                let source: [Float]
                if let cached = recordings[sample.file] {
                    source = cached
                } else {
                    do {
                        source = try readRecording(bank.directory.appendingPathComponent(sample.file))
                    } catch {
                        throw StudioError.invalidSample(lyric)
                    }
                    if cachedFrames + source.count > 6_000_000 {
                        recordings.removeAll(keepingCapacity: true)
                        cachedFrames = 0
                    }
                    recordings[sample.file] = source
                    cachedFrames += source.count
                }
                let offset = max(0, frames(for: sample.offset))
                let cutoff = frames(for: sample.cutoff)
                let end = min(source.count, cutoff < 0 ? offset - cutoff : source.count - cutoff)
                guard end - offset >= 16 else { throw StudioError.invalidSample(lyric) }
                let attack = max(0, min(sample.consonant, max(0, lead) + 12))
                let duration = noteEnd - onset
                let fixedFrames = min(frames(for: attack), duration / 3, end - offset - 8)
                let key = PeriodKey(file: sample.file, offset: offset, end: end, consonant: fixedFrames)
                let points = pitchPoints(for: group, previous: previous, onset: onset,
                                         totalFrames: duration, frame: frame)
                let result = source.withUnsafeBufferPointer { input in
                    let cropped = input.baseAddress?.advanced(by: offset)
                    let count = Int32(end - offset)
                    let period: Int32
                    if let cachedPeriod = periods[key] {
                        period = cachedPeriod
                    } else {
                        period = teto_note_period(cropped, count, Int32(sampleRate), Int32(fixedFrames))
                        periods[key] = period
                    }
                    return output.withUnsafeMutableBufferPointer { destination in
                        points.withUnsafeBufferPointer { values in
                            teto_mix_note_curve(cropped, count, Int32(sampleRate), Int32(fixedFrames), period,
                                                values.baseAddress, Int32(values.count), Int32(duration),
                                                Int32(visibleStart - onset), Float(track.volume),
                                                destination.baseAddress?.advanced(by: visibleStart - startFrame),
                                                Int32(visibleEnd - visibleStart))
                        }
                    }
                }
                guard result == 0 else { throw StudioError.invalidSample(lyric) }
            }
        }
        try Task.checkCancellation()
        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        return wave(output, gain: peak > 0.88 ? 0.88 / peak : 1)
    }

    private static func syllableGroups(in track: MelodyTrack) -> [[MelodyNote]] {
        var groups: [[MelodyNote]] = []
        for note in track.notes.sorted(by: { $0.start < $1.start }) {
            if note.expression.slur, let group = groups.last, group.last?.end == note.start,
               let lyric = group.first?.lyric, Voicebank.kana(lyric) != "っ" {
                groups[groups.count - 1].append(note)
            } else {
                groups.append([note])
            }
        }
        return groups
    }

    private static func pitchPoints(for notes: [MelodyNote], previous: MelodyNote?, onset: Int,
                                    totalFrames: Int, frame: (Int) -> Int) -> [TetoPitchPoint] {
        var points: [TetoPitchPoint] = []
        var previous = previous
        func add(_ time: Int, _ hz: Double) {
            guard (0..<totalFrames).contains(time) else { return }
            let point = TetoPitchPoint(frame: Int32(time), hz: Float(hz))
            if let last = points.last, last.frame == point.frame { points[points.count - 1] = point }
            else { points.append(point) }
        }
        for note in notes {
            let start = frame(note.start) - onset
            let end = frame(note.end) - onset
            let duration = max(1, end - start)
            let expression = note.expression
            let curve = expression.pitchCurve
            let initial = curve.first?.cents ?? 0
            let transition = min(duration / 2, frames(for: Double(expression.transitionMilliseconds)))
            let drift: Double
            if transition > 0, let previous, previous.end == note.start,
               Voicebank.kana(previous.lyric) != "っ" {
                let last = previous.expression.pitchCurve.last?.cents ?? 0
                drift = Double(previous.pitch - note.pitch) * 100 + last - initial
            } else {
                drift = 0
            }
            let base = frequency(note.pitch)
            if points.isEmpty, start > 0 { add(0, base * pow(2, (initial + drift) / 1200)) }
            let needsMotion = drift != 0 || expression.vibratoDepth > 0 || curve.count > 1
            let first = max(0, start)
            if needsMotion, first < end {
                var curveIndex = 0
                let granularity = sampleRate / 140
                for time in stride(from: first, to: end, by: granularity) {
                    let relative = time - start
                    let progress = Double(relative) / Double(duration)
                    while curveIndex + 1 < curve.count, curve[curveIndex + 1].position <= progress { curveIndex += 1 }
                    var offset = curve.isEmpty ? 0 : curve[curveIndex].cents
                    if curveIndex + 1 < curve.count, progress > curve[curveIndex].position {
                        let left = curve[curveIndex]
                        let right = curve[curveIndex + 1]
                        offset += (right.cents - left.cents) * (progress - left.position) / (right.position - left.position)
                    }
                    if drift != 0, relative < transition {
                        let remaining = 1 - Double(relative) / Double(transition)
                        offset += drift * remaining * remaining
                    }
                    let age = Double(relative) / Double(sampleRate)
                    let ramp = min(1, max(0, (age - 0.12) / 0.12))
                    offset += Double(expression.vibratoDepth) * ramp * sin(2 * .pi * expression.vibratoRate * age)
                    add(time, base * pow(2, offset / 1200))
                }
            } else {
                add(first, base * pow(2, initial / 1200))
            }
            previous = note
        }
        if points.isEmpty { add(0, frequency(notes[0].pitch)) }
        return points
    }

    static func preview(pitch: Int) -> Data {
        let length = sampleRate / 6
        let angularFrequency = frequency(pitch) * 2 * .pi / Double(sampleRate)
        let output = (0..<length).map { index -> Float in
            let attack = min(1, Double(index) / 200)
            let decay = pow(1 - Double(index) / Double(length), 3)
            let phase = Double(index) * angularFrequency
            return Float((sin(phase) + 0.2 * sin(phase * 2)) * attack * decay)
        }
        return wave(output, gain: 0.28)
    }

    private static func frequency(_ pitch: Int) -> Double {
        440 * pow(2, Double(pitch - 69) / 12)
    }

    private static func frames(for milliseconds: Double) -> Int {
        Int((milliseconds * Double(sampleRate) / 1000).rounded())
    }

    private static func readRecording(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard (8_000...192_000).contains(rate), (1...2).contains(file.processingFormat.channelCount),
              file.length > 16, file.length <= Int64(rate * 12),
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: pcm)
        guard let channels = pcm.floatChannelData, pcm.frameLength > 16 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let count = Int(pcm.frameLength)
        let channelCount = Int(pcm.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            for index in 0..<count {
                let value = channels[channel][index]
                if value.isFinite { mono[index] += value / Float(channelCount) }
            }
        }
        guard rate != Double(sampleRate) else { return mono }
        let ratio = rate / Double(sampleRate)
        let length = Int((Double(mono.count) / ratio).rounded())
        return (0..<length).map { index in
            let position = min(Double(mono.count - 1), Double(index) * ratio)
            let lower = Int(position)
            let upper = min(lower + 1, mono.count - 1)
            let fraction = Float(position - Double(lower))
            return mono[lower] + (mono[upper] - mono[lower]) * fraction
        }
    }

    private static func wave(_ samples: [Float], gain: Float) -> Data {
        let byteCount = UInt32(samples.count * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(byteCount))

        func appendInteger<T: FixedWidthInteger>(_ number: T) {
            var littleEndian = number.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendInteger(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendInteger(UInt32(16))
        appendInteger(UInt16(1)) // PCM
        appendInteger(UInt16(1)) // Mono
        appendInteger(UInt32(sampleRate))
        appendInteger(UInt32(sampleRate * 2))
        appendInteger(UInt16(2))
        appendInteger(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendInteger(byteCount)
        let headerSize = data.count
        data.count += Int(byteCount)
        data.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            for (index, sample) in samples.enumerated() {
                let scaled = sample.isFinite ? max(-1, min(1, sample * gain)) : 0
                let pcm = Int16((scaled * Float(Int16.max)).rounded()).littleEndian
                target.storeBytes(of: pcm, toByteOffset: headerSize + index * 2, as: Int16.self)
            }
        }
        return data
    }
}
