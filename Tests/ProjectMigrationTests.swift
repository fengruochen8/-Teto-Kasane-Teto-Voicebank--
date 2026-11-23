import XCTest
@testable import TetoMelody

final class ProjectMigrationTests: XCTestCase {
    private let legacyNote: [String: Any] = [
        "id": "E7AC341F-DADE-4F95-AE02-1EF3A4680D44",
        "start": 2,
        "length": 4,
        "pitch": 60,
        "lyric": "歌"
    ]

    func testVersion1GridProjectMigratesToCanonical480Ticks() throws {
        let source: [String: Any] = [
            "version": 1,
            "name": "  旧工程  ",
            "melody": ["tempo": 112, "notes": [legacyNote]]
        ]
        let document = try ProjectDocument.decode(jsonData(source))

        XCTAssertEqual(document.version, 3)
        XCTAssertEqual(document.name, "旧工程")
        XCTAssertEqual(document.melody.tracks.count, 1)
        XCTAssertEqual(document.melody.tracks[0].notes[0].start, 240)
        XCTAssertEqual(document.melody.tracks[0].notes[0].length, 480)
    }

    func testVersion2GridTrackMigratesToCanonical480Ticks() throws {
        let source: [String: Any] = [
            "version": 2,
            "name": "旧多轨",
            "melody": [
                "tempo": 128,
                "tracks": [["id": "64E2B868-5D8A-4D98-81E2-5049687C4A01", "name": "主旋律", "notes": [legacyNote]]]
            ]
        ]
        let document = try ProjectDocument.decode(jsonData(source))

        XCTAssertEqual(document.version, 3)
        XCTAssertEqual(document.melody.tracks[0].notes[0].start, 240)
        XCTAssertEqual(document.melody.tracks[0].notes[0].length, 480)
    }

    func testCurrentProjectPersistsLengthLoopAndExpression() throws {
        let expression = NoteExpression(slur: true, transitionMilliseconds: 85, timingMilliseconds: -35,
                                        vibratoDepth: 70, vibratoRate: 6.4,
                                        pitchCurve: [PitchPoint(position: 0.2, cents: -120), PitchPoint(position: 0.8, cents: 180)])
        let note = MelodyNote(start: 2_400, length: 720, pitch: 64, lyric: "ね", expression: expression)
        var melody = MelodyProject(tempo: 136, tracks: [MelodyTrack(name: "主唱", notes: [note])], barCount: 12)
        melody.loopRegion = MeasureLoop(firstBar: 3, endBar: 8)
        let decoded = try ProjectDocument.decode(try ProjectDocument(name: "持久化", melody: melody).encoded())

        XCTAssertEqual(decoded.melody.barCount, 12)
        XCTAssertEqual(decoded.melody.loopRegion, MeasureLoop(firstBar: 3, endBar: 8))
        XCTAssertEqual(decoded.melody.tracks[0].notes[0].expression, expression)
    }

    private func jsonData(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
