import AVFoundation
import Combine
import Foundation

@MainActor
final class StudioModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var project = StudioStorage.loadProject()
    @Published private(set) var bank = StudioStorage.loadBank()
    @Published var selectedID: UUID?
    @Published private(set) var entryStep = 0
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isRendering = false
    @Published private(set) var isPlaying = false
    @Published var loops = true {
        didSet { songPlayer?.numberOfLoops = loops ? -1 : 0 }
    }

    private var previewPlayer: AVAudioPlayer?
    private var songPlayer: AVAudioPlayer?
    private var cache: Data?

    var selected: MelodyNote? { project.notes.first { $0.id == selectedID } }

    var entryLocation: String {
        guard entryStep < MelodyProject.steps else { return "已到曲尾" }
        let bar = entryStep / MelodyProject.stepsPerBar + 1
        let beat = entryStep % MelodyProject.stepsPerBar / MelodyProject.stepsPerBeat + 1
        let subdivision = entryStep % MelodyProject.stepsPerBeat
        let position = "第\(bar)小节 第\(beat)拍" + (subdivision == 0 ? "" : " +\(subdivision)/4拍")
        let isInsideNote = project.notes.contains { $0.start < entryStep && entryStep < $0.end }
        return isInsideNote ? "\(position) · 音符内" : position
    }

    func moveEntryCursor(to step: Int) {
        entryStep = min(MelodyProject.steps, max(0, step))
    }

    func select(_ note: MelodyNote) {
        selectedID = note.id
        moveEntryCursor(to: note.start)
        audition(pitch: note.pitch)
    }

    func add(start: Int, pitch: Int) {
        guard let note = project.newNote(at: start, pitch: pitch), place(note) else { return }
        select(note)
    }

    func enterNote(pitch: Int) {
        guard let note = project.noteForKeyboard(at: entryStep, pitch: pitch), place(note) else { return }
        selectedID = note.id
        moveEntryCursor(to: note.end)
    }

    @discardableResult
    func place(_ note: MelodyNote) -> Bool {
        guard project.canPlace(note) else { return false }
        var updated = project
        if let index = updated.notes.firstIndex(where: { $0.id == note.id }) {
            updated.notes[index] = note
        } else {
            updated.notes.append(note)
        }
        update(updated)
        return true
    }

    func setLyric(_ text: String) {
        guard var note = selected else { return }
        note.lyric = String(text.prefix(12))
        place(note)
    }

    func deleteSelected() {
        guard let selectedID else { return }
        var updated = project
        updated.notes.removeAll { $0.id == selectedID }
        self.selectedID = nil
        update(updated)
    }

    func setTempo(_ tempo: Int) {
        var updated = project
        updated.tempo = min(MelodyProject.tempos.upperBound, max(MelodyProject.tempos.lowerBound, tempo))
        update(updated)
    }

    private func update(_ value: MelodyProject) {
        guard value != project else { return }
        project = value
        invalidateAudio()
        do {
            try StudioStorage.save(value)
        } catch {
            errorMessage = "旋律保存失败。\(error.localizedDescription)"
        }
    }

    func importZIP(_ url: URL) async {
        guard !isImporting && !isRendering else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let previous = bank
            let value = try await Task.detached(priority: .userInitiated) {
                let installed = try Voicebank.importZIP(url)
                do {
                    try StudioStorage.activate(installed)
                } catch {
                    try? FileManager.default.removeItem(at: installed.directory)
                    throw error
                }
                if let previous {
                    try? FileManager.default.removeItem(at: previous.directory)
                }
                return installed
            }.value
            bank = value
            invalidateAudio()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renderedAudio() async -> Data? {
        guard !isRendering && !isImporting else { return nil }
        if let cache { return cache }
        guard let bank else {
            errorMessage = StudioError.noVoicebank.localizedDescription
            return nil
        }
        let snapshot = project
        isRendering = true
        defer { isRendering = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try MelodyAudio.render(snapshot, bank: bank)
            }.value
            guard project == snapshot, self.bank?.id == bank.id else { return nil }
            cache = data
            return data
        } catch {
            if project == snapshot { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func sing() async {
        if isPlaying {
            stop()
            return
        }
        guard let data = await renderedAudio() else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = loops ? -1 : 0
            player.delegate = self
            previewPlayer?.stop()
            guard player.play() else { throw StudioError.playback }
            songPlayer = player
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        songPlayer?.stop()
        songPlayer = nil
        isPlaying = false
    }

    func audition(pitch: Int) {
        guard !isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            previewPlayer?.stop()
            let player = try AVAudioPlayer(data: MelodyAudio.preview(pitch: pitch))
            guard player.play() else { throw StudioError.playback }
            previewPlayer = player
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func invalidateAudio() {
        cache = nil
        stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = songPlayer, ObjectIdentifier(current) == id else { return }
            stop()
        }
    }
}
