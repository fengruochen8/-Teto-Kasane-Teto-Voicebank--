import Foundation
import ZIPFoundation

struct VoiceSample: Codable, Sendable {
    let file: String
    let offset: Double
    let consonant: Double
    let cutoff: Double
    let preutterance: Double
}

struct Voicebank: Sendable {
    let id: UUID
    let samples: [String: VoiceSample]

    var directory: URL { StudioStorage.bankDirectory(for: id) }

    static func kana(_ lyric: String) -> String {
        let trimmed = lyric.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let hiragana = trimmed.unicodeScalars.map { scalar in
            if (0x30A1...0x30F6).contains(scalar.value), let converted = Unicode.Scalar(scalar.value - 0x60) {
                return String(converted)
            }
            return String(scalar)
        }
        return hiragana.joined()
    }

    static func importZIP(_ url: URL) throws -> Voicebank {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 128 * 1024 * 1024 else { throw StudioError.invalidArchive }
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw StudioError.invalidArchive
        }

        var waveEntries: [String: Entry] = [:]
        var settings: [(entry: Entry, parents: [String])] = []
        for (index, entry) in archive.enumerated() {
            guard index < 4096 else { throw StudioError.invalidArchive }
            guard entry.type == .file else { continue }
            // The official bank uses Shift-JIS names without the ZIP UTF-8 flag.
            let paths = [entry.path(using: .shiftJIS), entry.path]
                .map { $0.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping }
                .filter { !$0.isEmpty }
            guard let path = paths.first else { continue }
            if path.lowercased().hasSuffix(".wav"), entry.uncompressedSize <= 5 * 1024 * 1024 {
                for name in paths { waveEntries[name] = entry }
            } else if path.lowercased().hasSuffix("/oto.ini") || path.lowercased() == "oto.ini" {
                guard entry.uncompressedSize <= 512 * 1024 else { throw StudioError.invalidArchive }
                let parents = paths.map { path in
                    path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
                }
                settings.append((entry, parents))
            }
        }
        settings.sort {
            let left = $0.parents[0].split(separator: "/").count
            let right = $1.parents[0].split(separator: "/").count
            if left != right { return left < right }
            return $0.parents[0] < $1.parents[0]
        }

        let id = UUID()
        let directory = StudioStorage.bankDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed = false
        defer { if !installed { try? FileManager.default.removeItem(at: directory) } }

        var samples: [String: VoiceSample] = [:]
        var totalBytes: UInt64 = 0
        for setting in settings {
            var configuration = Data()
            let checksum = try archive.extract(setting.entry) { chunk in
                guard configuration.count + chunk.count <= 512 * 1024 else {
                    throw StudioError.invalidArchive
                }
                configuration.append(chunk)
            }
            guard checksum == setting.entry.checksum,
                  let text = String(data: configuration, encoding: .utf8)
                    ?? String(data: configuration, encoding: .shiftJIS) else {
                throw StudioError.invalidArchive
            }
            for row in text.split(whereSeparator: \.isNewline) {
                let pair = row.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let fields = pair[1].split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 6 else { continue }

                let relativeName = pair[0].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
                let alias = kana(fields[0].isEmpty ? String((relativeName as NSString).deletingPathExtension) : String(fields[0]))
                guard (1...4).contains(alias.count),
                      alias.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) }),
                      samples[alias] == nil,
                      let entry = setting.parents.lazy.compactMap({ waveEntries[$0 + relativeName] }).first else { continue }
                let timing = fields.dropFirst().compactMap {
                    Double($0.trimmingCharacters(in: .whitespaces))
                }
                guard timing.count == 5, timing.allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { continue }
                guard samples.count < 1024 else { throw StudioError.invalidArchive }

                totalBytes += entry.uncompressedSize
                guard totalBytes <= 96 * 1024 * 1024 else { throw StudioError.invalidArchive }

                // Materialize only selected WAVs under generated names in app storage.
                let name = "\(samples.count).wav"
                let destination = directory.appendingPathComponent(name)
                var recording = Data()
                let checksum = try archive.extract(entry) { chunk in
                    guard UInt64(recording.count + chunk.count) <= entry.uncompressedSize else {
                        throw StudioError.invalidArchive
                    }
                    recording.append(chunk)
                }
                guard checksum == entry.checksum,
                      UInt64(recording.count) == entry.uncompressedSize,
                      recording.starts(with: "RIFF".utf8),
                      recording.dropFirst(8).starts(with: "WAVE".utf8) else {
                    throw StudioError.invalidArchive
                }
                try recording.write(to: destination, options: .atomic)
                samples[alias] = VoiceSample(
                    file: name, offset: timing[0], consonant: timing[1],
                    cutoff: timing[2], preutterance: timing[3]
                )
            }
        }

        guard samples["ら"] != nil, samples["あ"] != nil else { throw StudioError.unsupportedVoicebank }
        try JSONEncoder().encode(samples).write(to: directory.appendingPathComponent("Samples.json"), options: .atomic)
        installed = true
        return Voicebank(id: id, samples: samples)
    }
}

enum StudioError: LocalizedError {
    case invalidArchive
    case unsupportedVoicebank
    case missingLyric(String)
    case invalidSample(String)
    case noVoicebank
    case emptyMelody
    case playback

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "无法读取这个 ZIP。请重新下载官方日语普通单独音音源。"
        case .unsupportedVoicebank: return "这个 ZIP 缺少日语单独音。请选择官网的 TETO-tandoku-100619.zip。"
        case .missingLyric(let lyric): return "音源里找不到「\(lyric)」。请为这个音符填写一个假名或日语音节。"
        case .invalidSample(let lyric): return "无法合成「\(lyric)」的录音，请重新导入官方音源。"
        case .noVoicebank: return "请先从「文件」导入重音Teto音源。"
        case .emptyMelody: return "先在网格中加入一个音符。"
        case .playback: return "无法播放音频。请检查当前的音频输出后重试。"
        }
    }
}
