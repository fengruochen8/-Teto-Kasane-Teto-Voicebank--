import AVFoundation
import Combine
import Foundation

@MainActor
final class StudioModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var project = MelodyProject()
    @Published private(set) var currentProject: LocalProject?
    @Published private(set) var recentProjects: [LocalProject] = []
    @Published private(set) var isHandlingProjectFile = false
    @Published private(set) var saveStatus: String?
    @Published private(set) var bank = StudioStorage.loadBank()
    @Published var selectedID: UUID?
    @Published private(set) var entryStep = 0
    @Published private(set) var transportStep = 0
    @Published private var undoHistory: [EditSnapshot] = []
    @Published private var redoHistory: [EditSnapshot] = []
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
    private var lyricEditNote: UUID?
    private var externalProjectURL: URL?
    private var didLoadProjectLibrary = false

    private struct EditSnapshot {
        let project: MelodyProject
        let selectedID: UUID?
        let entryStep: Int
    }

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var canSaveToSource: Bool { externalProjectURL != nil }
    var isBusy: Bool { isHandlingProjectFile || isImporting || isRendering }

    var playbackPosition: Double? {
        guard isPlaying, let player = songPlayer, player.duration > 0 else { return nil }
        return min(Double(MelodyProject.steps), max(0, player.currentTime / player.duration * Double(MelodyProject.steps)))
    }

    var selected: MelodyNote? { project.notes.first { $0.id == selectedID } }

    func loadProjectLibrary() {
        guard !didLoadProjectLibrary else { return }
        didLoadProjectLibrary = true
        do {
            try ProjectLibrary.migrateLegacy()
            recentProjects = try ProjectLibrary.recent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createProject(named name: String, melody: MelodyProject = MelodyProject()) {
        guard !isBusy else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = ProjectDocument(name: trimmed.isEmpty ? "未命名工程" : String(trimmed.prefix(64)), melody: melody)
        openLocalProject(LocalProject(document: document))
    }

    func openLocalProject(_ record: LocalProject) {
        guard !isBusy else { return }
        do {
            try installProject(record, url: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openExternalProject(_ url: URL) async {
        guard !isBusy else {
            errorMessage = "请等当前操作完成后，再打开工程。"
            return
        }
        isHandlingProjectFile = true
        defer { isHandlingProjectFile = false }
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try ProjectLibrary.open(url)
            }.value
            try installProject(opened, url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showWelcome() {
        guard !isBusy else { return }
        do {
            if let currentProject { try ProjectLibrary.save(currentProject) }
            recentProjects = try ProjectLibrary.recent()
            invalidateAudio()
            previewPlayer?.stop()
            currentProject = nil
            externalProjectURL = nil
            saveStatus = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveToSource() async {
        guard !isBusy, let currentProject, let url = externalProjectURL else { return }
        isHandlingProjectFile = true
        defer { isHandlingProjectFile = false }
        do {
            let bookmark = try await Task.detached(priority: .userInitiated) {
                try ProjectLibrary.write(currentProject.document, to: url)
                return ProjectLibrary.bookmark(for: url)
            }.value
            saveStatus = "已保存到文件"
            if let bookmark, var record = self.currentProject, record.id == currentProject.id {
                record.externalBookmark = bookmark
                self.currentProject = record
                do {
                    try ProjectLibrary.save(record)
                } catch {
                    errorMessage = "工程文件已保存，更新本机工程信息时出错。\n\(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = "无法更新原工程文件。请使用「另存为」保存副本。\n\(error.localizedDescription)"
        }
    }

    func recordProjectExport(to url: URL, projectID: UUID) {
        guard var record = currentProject, record.id == projectID else { return }
        externalProjectURL = url
        record.externalBookmark = ProjectLibrary.bookmark(for: url)
        currentProject = record
        do {
            try ProjectLibrary.save(record)
            saveStatus = "已保存到文件"
        } catch {
            errorMessage = "文件已导出，保存本机工程信息时出错。\n\(error.localizedDescription)"
        }
    }

    private func installProject(_ record: LocalProject, url: URL?) throws {
        if let currentProject, currentProject.id != record.id {
            try ProjectLibrary.save(currentProject)
        }
        var next = record
        next.updatedAt = Date()
        try ProjectLibrary.save(next)

        invalidateAudio()
        previewPlayer?.stop()
        project = next.document.melody
        selectedID = nil
        entryStep = 0
        transportStep = 0
        undoHistory.removeAll()
        redoHistory.removeAll()
        finishLyricEdit()
        saveStatus = nil
        externalProjectURL = url ?? next.externalBookmark.flatMap { ProjectLibrary.url(for: $0) }
        currentProject = next
    }

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

    func seek(to step: Int) {
        transportStep = min(MelodyProject.steps - 1, max(0, step))
        if let player = songPlayer, isPlaying {
            player.currentTime = transportTime(duration: player.duration)
        }
    }

    private func transportTime(duration: TimeInterval) -> TimeInterval {
        duration * Double(transportStep) / Double(MelodyProject.steps)
    }

    func select(_ note: MelodyNote) {
        finishLyricEdit()
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
    func place(_ note: MelodyNote, lyricEdit: UUID? = nil) -> Bool {
        guard project.canPlace(note) else { return false }
        var updated = project
        if let index = updated.notes.firstIndex(where: { $0.id == note.id }) {
            updated.notes[index] = note
        } else {
            updated.notes.append(note)
        }
        update(updated, lyricEdit: lyricEdit)
        return true
    }

    func setLyric(_ text: String) {
        guard var note = selected else { return }
        note.lyric = String(text.prefix(12))
        place(note, lyricEdit: note.id)
    }

    func finishLyricEdit() {
        lyricEditNote = nil
    }

    func deleteSelected() {
        guard let selectedID else { return }
        var updated = project
        updated.notes.removeAll { $0.id == selectedID }
        update(updated)
        self.selectedID = nil
    }

    func setTempo(_ tempo: Int) {
        var updated = project
        updated.tempo = min(MelodyProject.tempos.upperBound, max(MelodyProject.tempos.lowerBound, tempo))
        update(updated)
    }

    private var editSnapshot: EditSnapshot {
        EditSnapshot(project: project, selectedID: selectedID, entryStep: entryStep)
    }

    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(editSnapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(editSnapshot)
        restore(next)
    }

    private func restore(_ snapshot: EditSnapshot) {
        finishLyricEdit()
        apply(snapshot.project)
        selectedID = snapshot.selectedID
        moveEntryCursor(to: snapshot.entryStep)
    }

    private func update(_ value: MelodyProject, lyricEdit: UUID? = nil) {
        guard value != project else { return }
        if lyricEdit == nil || lyricEdit != lyricEditNote {
            undoHistory.append(editSnapshot)
            if undoHistory.count > 64 {
                undoHistory.removeFirst()
            }
            redoHistory.removeAll()
        }
        lyricEditNote = lyricEdit
        apply(value)
    }

    private func apply(_ value: MelodyProject) {
        guard var active = currentProject else { return }
        project = value
        active.document.melody = value
        active.updatedAt = Date()
        currentProject = active
        saveStatus = nil
        invalidateAudio()
        do {
            try ProjectLibrary.save(active)
        } catch {
            errorMessage = "旋律保存失败。\(error.localizedDescription)"
        }
    }

    func importZIP(_ url: URL) async {
        guard !isBusy else { return }
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
        guard !isBusy, let projectID = currentProject?.id else { return nil }
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
            guard currentProject?.id == projectID else { return nil }
            guard project == snapshot, self.bank?.id == bank.id else {
                errorMessage = "合成期间旋律或音源有更新，请重新试听或导出。"
                return nil
            }
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
            player.currentTime = transportTime(duration: player.duration)
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
