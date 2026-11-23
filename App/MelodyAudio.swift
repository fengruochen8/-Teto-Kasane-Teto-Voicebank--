import AVFoundation
import Foundation

enum MelodyAudio {
    static let sampleRate = 44_100

    static func render(_ project: MelodyProject, bank: Voicebank) throws -> Data {
        guard !project.notes.isEmpty else { throw StudioError.emptyMelody }
        let framesPerStep = Double(sampleRate * 60) / Double(project.tempo * MelodyProject.stepsPerBeat)
        let totalFrames = Int((framesPerStep * Double(MelodyProject.steps)).rounded())
        var output = [Float](repeating: 0, count: totalFrames)
        var recordings: [String: [Float]] = [:]

        for note in project.notes.sorted(by: { $0.start < $1.start }) {
            let inputLyric = Voicebank.kana(note.lyric)
            let lyric = inputLyric.isEmpty ? "ら" : inputLyric
            guard let sample = bank.samples[lyric] else { throw StudioError.missingLyric(note.lyric) }

            let source: [Float]
            if let cached = recordings[sample.file] {
                source = cached
            } else {
                do {
                    source = try readRecording(bank.directory.appendingPathComponent(sample.file))
                } catch {
                    throw StudioError.invalidSample(lyric)
                }
                recordings[sample.file] = source
            }

            let offset = max(0, frames(for: sample.offset))
            let cutoff = frames(for: sample.cutoff)
            let end = min(source.count, cutoff < 0 ? offset - cutoff : source.count - cutoff)
            guard end - offset >= 16 else { throw StudioError.invalidSample(lyric) }

            let startBeat = Int((Double(note.start) * framesPerStep).rounded())
            let endBeat = Int((Double(note.end) * framesPerStep).rounded())
            let preutterance = max(0, min(sample.preutterance, 120))
            let lead = min(startBeat, frames(for: preutterance))
            let start = startBeat - lead
            let renderedCount = endBeat - start
            var rendered = [Float](repeating: 0, count: renderedCount)
            // Leave enough voiced material for even a sixteenth note to change pitch.
            let attack = max(0, min(sample.consonant, preutterance + 12))
            let fixedFrames = min(frames(for: attack), renderedCount / 3, end - offset - 8)
            let result = source.withUnsafeBufferPointer { input in
                rendered.withUnsafeMutableBufferPointer { destination in
                    teto_render_note(
                        input.baseAddress?.advanced(by: offset), Int32(end - offset),
                        Int32(sampleRate), Int32(fixedFrames),
                        Float(frequency(note.pitch)), destination.baseAddress, Int32(renderedCount)
                    )
                }
            }
            guard result == 0 else { throw StudioError.invalidSample(lyric) }
            for (index, value) in rendered.enumerated() {
                let onset = min(1, Float(index) / Float(sampleRate / 500))
                output[start + index] += value * onset
            }
        }

        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        let gain = peak > 0.0001 ? min(3, 0.88 / peak) : 1
        return wave(output, gain: gain)
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
        for sample in samples {
            let scaled = sample.isFinite ? max(-1, min(1, sample * gain)) : 0
            appendInteger(Int16((scaled * Float(Int16.max)).rounded()))
        }
        return data
    }
}
