import XCTest
@testable import TetoMelody

final class ProjectInterchangeTests: XCTestCase {
    private func fixture() -> MelodyProject {
        let lead = MelodyTrack(name: "主唱", notes: [
            MelodyNote(start: 0, length: 480, pitch: 60, lyric: "さ"),
            MelodyNote(start: 480, length: 480, pitch: 62, lyric: "く"),
            MelodyNote(start: 1_920 * 6, length: 960, pitch: 67, lyric: "ら")
        ], volume: 1.15)
        let harmony = MelodyTrack(name: "和声", notes: [
            MelodyNote(start: 0, length: 960, pitch: 55, lyric: "あ"),
            MelodyNote(start: 1_920 * 6, length: 960, pitch: 62, lyric: "う")
        ], isMuted: true, volume: 0.7)
        return MelodyProject(tempo: 132, tracks: [lead, harmony], barCount: 12)
    }

    func testMIDIRoundTripKeepsTracksTimingAndLyrics() throws {
        let original = fixture()
        let encoded = try ProjectInterchange.midi.encode(original, title: "测试", selectedTrackID: nil)
        let imported = try ProjectInterchange.midi.decode(encoded).melody

        XCTAssertEqual(imported.tempo, 132)
        XCTAssertEqual(imported.barCount, 12)
        XCTAssertEqual(imported.tracks.count, 2)
        XCTAssertEqual(imported.tracks[0].name, "主唱")
        XCTAssertEqual(imported.tracks[0].notes.map(\.start), original.tracks[0].notes.map(\.start))
        XCTAssertEqual(imported.tracks[0].notes.map(\.length), original.tracks[0].notes.map(\.length))
        XCTAssertEqual(imported.tracks[0].notes.map(\.lyric), original.tracks[0].notes.map(\.lyric))
    }

    func testUSTRoundTripUsesSelectedTrackAndRetainsRests() throws {
        let original = fixture()
        let encoded = try ProjectInterchange.ust.encode(original, title: "单轨", selectedTrackID: original.tracks[0].id)
        let imported = try ProjectInterchange.ust.decode(encoded).melody

        XCTAssertEqual(imported.tracks.count, 1)
        XCTAssertEqual(imported.tempo, original.tempo)
        XCTAssertEqual(imported.barCount, original.barCount)
        XCTAssertEqual(imported.tracks[0].notes.map(\.start), original.tracks[0].notes.map(\.start))
        XCTAssertEqual(imported.tracks[0].notes.map(\.lyric), original.tracks[0].notes.map(\.lyric))
    }

    func testUSTXRoundTripKeepsMuteSoloAndVolume() throws {
        let original = fixture()
        let encoded = try ProjectInterchange.ustx.encode(original, title: "多轨", selectedTrackID: nil)
        let imported = try ProjectInterchange.ustx.decode(encoded).melody

        XCTAssertEqual(imported.tracks.count, 2)
        XCTAssertEqual(imported.tracks[1].isMuted, true)
        XCTAssertEqual(imported.tracks[0].notes.map(\.pitch), original.tracks[0].notes.map(\.pitch))
        XCTAssertEqual(imported.tracks[0].notes.map(\.lyric), original.tracks[0].notes.map(\.lyric))
        XCTAssertEqual(imported.tracks[0].volume, original.tracks[0].volume, accuracy: 0.0001)
    }

    func testMIDIOverlapsAreSplitIntoMonophonicTracks() throws {
        let source = Data([
            0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0,
            0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 20,
            0, 0x90, 60, 100, 0x40, 0x90, 64, 100, 0x40, 0x80, 60, 0,
            0, 0x80, 64, 0, 0, 0xFF, 0x2F, 0
        ])
        let result = try ProjectInterchange.midi.decode(source)

        XCTAssertEqual(result.melody.tracks.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("重叠音符") })
        XCTAssertTrue(result.melody.tracks.allSatisfy { $0.isValid(limit: result.melody.steps) })
    }

    func testUSTXCoalescesNonOverlappingPartsForOneTrack() throws {
        let source = """
        ustx_version: '0.6'
        resolution: 480
        tempos:
        - position: 0
          bpm: 120
        tracks:
        - track_name: 主唱
          volume: 0
        voice_parts:
        - name: A段
          track_no: 0
          position: 0
          duration: 1920
          notes:
          - position: 0
            duration: 480
            tone: 60
            lyric: あ
        - name: B段
          track_no: 0
          position: 3840
          duration: 1920
          notes:
          - position: 0
            duration: 480
            tone: 62
            lyric: い
        """

        let result = try ProjectInterchange.ustx.decode(Data(source.utf8))
        XCTAssertEqual(result.melody.tracks.count, 1)
        XCTAssertEqual(result.melody.tracks[0].notes.map(\.start), [0, 3_840])
    }
}
