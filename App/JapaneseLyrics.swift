import Foundation
import IPADic
import Mecab_Swift

enum JapaneseLyrics {
    private static let smallKana: Set<Character> = Set("ぁぃぅぇぉゃゅょゎ")
    private static let vowelGroups: [(kana: String, vowel: String)] = [
        ("あかがさざただなはばぱまやらわぁゃゎ", "あ"),
        ("いきぎしじちぢにひびぴみりゐぃ", "い"),
        ("うくぐすずつづぬふぶぷむゆるゔぅゅ", "う"),
        ("えけげせぜてでねへべぺめれゑぇ", "え"),
        ("おこごそぞとどのほぼぽもよろをぉょ", "お")
    ]

    static func reading(for source: String) throws -> String {
        let text = try normalized(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let tokenizer: Tokenizer
        do {
            tokenizer = try Tokenizer(dictionary: IPADic())
        } catch {
            throw LyricsError.dictionaryUnavailable
        }

        // Keep punctuation and any unresolved text so the preview never silently drops lyrics.
        var reading = ""
        var cursor = text.startIndex
        for token in tokenizer.tokenize(text: text, transliteration: .hiragana) {
            guard token.range.lowerBound >= cursor else { continue }
            reading.append(contentsOf: text[cursor..<token.range.lowerBound])
            let kana = Voicebank.kana(token.reading)
            if token.partOfSpeech == .particle && kana == "は" {
                reading.append("わ")
            } else if token.partOfSpeech == .particle && kana == "へ" {
                reading.append("え")
            } else {
                reading.append(contentsOf: kana.isEmpty || kana == "*" ? token.base : kana)
            }
            cursor = token.range.upperBound
        }
        reading.append(contentsOf: text[cursor...])
        return Voicebank.kana(reading)
    }

    static func syllables(in reading: String, availableSamples: Set<String>?) throws -> [String] {
        let kana = Voicebank.kana(try normalized(reading))
        let phrases = kana.split(whereSeparator: isSeparator)
        var result: [String] = []
        for phrase in phrases {
            var cursor = phrase.startIndex
            var previous: String?
            while cursor < phrase.endIndex {
                let character = phrase[cursor]
                phrase.formIndex(after: &cursor)

                let syllable: String
                if character == "ー" {
                    guard let last = previous?.last, let vowel = vowelGroups.first(where: { $0.kana.contains(last) }) else {
                        throw LyricsError.unplacedLongVowel
                    }
                    syllable = vowel.vowel
                } else {
                    guard isKana(character) else { throw LyricsError.unresolved(character) }
                    if cursor < phrase.endIndex, smallKana.contains(phrase[cursor]),
                       !smallKana.contains(character), character != "っ", character != "ん" {
                        syllable = String([character, phrase[cursor]])
                        phrase.formIndex(after: &cursor)
                    } else {
                        syllable = String(character)
                    }
                }

                if let availableSamples, syllable != "っ", !availableSamples.contains(syllable) {
                    throw LyricsError.unavailableSample(syllable)
                }
                result.append(syllable)
                previous = syllable
            }
        }
        return result
    }

    private static func normalized(_ text: String) throws -> String {
        guard text.utf16.count <= 512 else { throw LyricsError.tooLong }
        let normalized = text.precomposedStringWithCompatibilityMapping
        guard normalized.utf16.count <= 512 else { throw LyricsError.tooLong }
        return normalized
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) }
    }

    private enum LyricsError: LocalizedError {
        case tooLong
        case dictionaryUnavailable
        case unresolved(Character)
        case unplacedLongVowel
        case unavailableSample(String)

        var errorDescription: String? {
            switch self {
            case .tooLong: return "歌词太长，请分成较短的句子再录入。"
            case .dictionaryUnavailable: return "无法打开日语词典。可在下方直接填写假名。"
            case .unresolved(let character): return "「\(character)」还没有可用读音，请在假名框修正。"
            case .unplacedLongVowel: return "「ー」前没有可延长的元音，请在假名框修正。"
            case .unavailableSample(let syllable): return "当前音源没有「\(syllable)」的采样，请在假名框修正。"
            }
        }
    }
}
