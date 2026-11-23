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
    @Published private(set) var selectedID: UUID?
    @Published private(set) var selectedIDs: Set<UUID> = []
    @Published private(set) var hasCopiedNotes = false
    @Published var importNotice: String?
    @Published private(set) var activeTrackID: UUID?
    @Published private(set) var entryStep = 0
    @Published private(set) var transportStep = 0
    @Published private var undoHistory: [EditSnapshot] = []
    @Published private var redoHistory: [EditSnapshot] = []
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isRendering = false
    @Published private(set) var isPlaying = false
    @Published var loops = true {
        didSet {
            guard oldValue != loops else { return }
            if project.loopRegion != nil { stop() }
            else { songPlayer?.numberOfLoops = loops ? -1 : 0 }
        }
    }

    private var previewPlayer: AVAudioPlayer?
    private var songPlayer: AVAudioPlayer?
    private struct RenderRequest: Equatable {
        let window: Range<Int>?
        let trackID: UUID?
    }

    private var cache: (request: RenderRequest, data: Data)?
    private var renderTask: Task<Data, Error>?
    private var playingRegion: Range<Int>?
    private var copiedNotes: [MelodyNote] = []
    private var autosaveTask: Task<Void, Never>?
    private var lyricEditNote: UUID?
    private var externalProjectURL: URL?
    private var didLoadProjectLibrary = false

    private struct EditSnapshot {
        let project: MelodyProject
        let selectedID: UUID?
        let selectedIDs: Set<UUID>
        let activeTrackID: UUID?
        let entryStep: Int
    }

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var canSaveToSource: Bool { externalProjectURL != nil }
    var isBusy: Bool { isHandlingProjectFile || isImporting || isRendering }

    var playbackPosition: Double? {
        guard isPlaying, let player = songPlayer, let region = playingRegion, player.duration > 0 else { return nil }
        return Double(region.lowerBound) + min(1, max(0, player.currentTime / player.duration)) * Double(region.count)
    }

    var activeTrack: MelodyTrack? {
        project.tracks.first { $0.id == activeTrackID } ?? project.tracks.first
    }

    var selected: MelodyNote? { activeTrack?.notes.first { $0.id == selectedID } }

    var canSlurSelectedNote: Bool {
        guard let note = selected else { return false }
        return activeTrack?.notes.contains { $0.end == note.start && Voicebank.kana($0.lyric) != "っ" } == true
    }

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

    func importArrangement(_ url: URL, format: ProjectInterchange) async {
        guard !isBusy else { return }
        isHandlingProjectFile = true
        defer { isHandlingProjectFile = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try format.decode(ProjectLibrary.coordinatedRead(url))
            }.value
            let rawName = url.deletingPathExtension().lastPathComponent
            let cleanName = rawName.components(separatedBy: .controlCharacters).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = cleanName.isEmpty ? "导入的旋律" : String(cleanName.prefix(64))
            let document = ProjectDocument(name: name, melody: result.melody)
            try installProject(LocalProject(document: document), url: nil)
            if !result.warnings.isEmpty { importNotice = result.warnings.joined(separator: "\n") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportArrangement(_ format: ProjectInterchange) async -> Data? {
        guard !isBusy, let record = currentProject else { return nil }
        isHandlingProjectFile = true
        defer { isHandlingProjectFile = false }
        let trackID = activeTrack?.id
        do {
            return try await Task.detached(priority: .userInitiated) {
                try format.encode(record.document.melody, title: record.document.name, selectedTrackID: trackID)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func showWelcome() {
        guard !isBusy else { return }
        do {
            if let currentProject { try ProjectLibrary.save(currentProject) }
            autosaveTask?.cancel()
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
        autosaveTask?.cancel()

        invalidateAudio()
        previewPlayer?.stop()
        project = next.document.melody
        activeTrackID = project.tracks.first?.id
        clearSelection()
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
        guard entryStep < project.steps else { return "已到曲尾" }
        let bar = entryStep / MelodyProject.stepsPerBar + 1
        let beat = entryStep % MelodyProject.stepsPerBar / MelodyProject.stepsPerBeat + 1
        let subdivision = entryStep % MelodyProject.stepsPerBeat
        let position = "第\(bar)小节 第\(beat)拍" + (subdivision == 0 ? "" : " +\(subdivision) tick")
        let isInsideNote = activeTrack?.notes.contains { $0.start < entryStep && entryStep < $0.end } ?? false
        return isInsideNote ? "\(position) · 音符内" : position
    }

    func moveEntryCursor(to step: Int) {
        entryStep = min(project.steps, max(0, step))
    }

    func seek(to step: Int) {
        transportStep = min(project.steps - 1, max(0, step))
        guard let player = songPlayer, let region = playingRegion else { return }
        if region.contains(transportStep) { player.currentTime = transportTime(duration: player.duration, region: region) }
        else { stop() }
    }

    private func transportTime(duration: TimeInterval, region: Range<Int>) -> TimeInterval {
        let offset = region.contains(transportStep) ? transportStep - region.lowerBound : 0
        return duration * Double(offset) / Double(region.count)
    }

    func resizeProject(to bars: Int) {
        guard (1...MelodyProject.maxBars).contains(bars), bars != project.barCount else { return }
        if project.tracks.contains(where: { $0.notes.contains { $0.end > bars * MelodyProject.stepsPerBar } }) {
            errorMessage = "曲尾仍有音符，请先移动或删除这些音符。"
            return
        }
        var updated = project
        updated.barCount = bars
        if let loop = updated.loopRegion, loop.endBar > bars {
            updated.loopRegion = loop.firstBar < bars ? MeasureLoop(firstBar: loop.firstBar, endBar: bars) : nil
        }
        update(updated)
    }

    func setLoop(firstBar: Int, endBar: Int) {
        guard firstBar >= 0, endBar <= project.barCount, firstBar < endBar else { return }
        var updated = project
        updated.loopRegion = MeasureLoop(firstBar: firstBar, endBar: endBar)
        update(updated)
        loops = true
        seek(to: firstBar * MelodyProject.stepsPerBar)
    }

    func clearLoop() {
        var updated = project
        updated.loopRegion = nil
        update(updated)
    }

    func selectTrack(_ id: UUID) {
        guard activeTrack?.id != id, project.tracks.contains(where: { $0.id == id }) else { return }
        finishLyricEdit()
        activeTrackID = id
        clearSelection()
    }

    func addTrack() {
        guard currentProject != nil, project.tracks.count < MelodyProject.maxTracks else { return }
        let count = project.tracks.count
        let track = MelodyTrack(name: count == 1 ? "和声" : "和声\(count)")
        var updated = project
        updated.tracks.append(track)
        update(updated)
        selectTrack(track.id)
    }

    func toggleMute(_ id: UUID) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        var updated = project
        updated.tracks[index].isMuted.toggle()
        update(updated)
    }

    func toggleSolo(_ id: UUID) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        var updated = project
        updated.tracks[index].isSolo.toggle()
        update(updated)
    }

    func updateTrack(_ id: UUID, name: String, volume: Double) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MelodyTrack.isValidName(trimmed), (0...2).contains(volume) else {
            errorMessage = "请输入1至32个字符的音轨名称和有效音量。"
            return
        }
        var updated = project
        updated.tracks[index].name = trimmed
        updated.tracks[index].volume = volume
        update(updated)
    }

    func duplicateTrack(_ id: UUID) {
        guard project.tracks.count < MelodyProject.maxTracks,
              let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        var copy = project.tracks[index]
        copy.id = UUID()
        copy.name = String(copy.name.prefix(29)) + " 副本"
        copy.isSolo = false
        for index in copy.notes.indices { copy.notes[index].id = UUID() }
        var updated = project
        updated.tracks.insert(copy, at: index + 1)
        update(updated)
        selectTrack(copy.id)
    }

    func moveTrack(_ id: UUID, by offset: Int) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }),
              project.tracks.indices.contains(index + offset) else { return }
        var updated = project
        updated.tracks.swapAt(index, index + offset)
        update(updated)
    }

    func removeTrack(_ id: UUID) {
        guard project.tracks.count > 1, let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        var updated = project
        updated.tracks.remove(at: index)
        update(updated)
        if activeTrackID == id {
            activeTrackID = updated.tracks[min(index, updated.tracks.count - 1)].id
            clearSelection()
        }
    }

    func clearSelection() {
        setSelection([])
    }

    func setSelection(_ ids: Set<UUID>, primary: UUID? = nil) {
        finishLyricEdit()
        let selection = (activeTrack?.notes ?? []).filter { ids.contains($0.id) }
        selectedIDs = Set(selection.map(\.id))
        if let primary, selectedIDs.contains(primary) { selectedID = primary }
        else { selectedID = selection.min(by: { $0.start < $1.start })?.id }
    }

    func select(_ note: MelodyNote) {
        setSelection([note.id], primary: note.id)
        moveEntryCursor(to: note.start)
        audition(pitch: note.pitch)
    }

    func add(start: Int, pitch: Int) {
        guard let note = activeTrack?.newNote(at: start, pitch: pitch, limit: project.steps), place(note) else { return }
        select(note)
    }

    func enterNote(pitch: Int) {
        guard let note = activeTrack?.noteForKeyboard(at: entryStep, pitch: pitch, limit: project.steps), place(note) else { return }
        setSelection([note.id], primary: note.id)
        moveEntryCursor(to: note.end)
    }

    @discardableResult
    func place(_ note: MelodyNote, lyricEdit: UUID? = nil) -> Bool {
        guard let track = activeTrack, track.canPlace(note, limit: project.steps),
              let index = project.tracks.firstIndex(where: { $0.id == track.id }) else { return false }
        var updated = project
        if let noteIndex = track.notes.firstIndex(where: { $0.id == note.id }) {
            updated.tracks[index].notes[noteIndex] = note
        } else {
            updated.tracks[index].notes.append(note)
        }
        update(updated, lyricEdit: lyricEdit)
        return true
    }

    func copySelection() {
        guard let track = activeTrack, !selectedIDs.isEmpty else { return }
        copiedNotes = track.notes.filter { selectedIDs.contains($0.id) }.sorted { $0.start < $1.start }
        hasCopiedNotes = !copiedNotes.isEmpty
    }

    func pasteNotes() {
        guard let origin = copiedNotes.first?.start else { return }
        let notes = copiedNotes.map { note in
            var copy = note
            copy.id = UUID()
            copy.start = entryStep + note.start - origin
            return copy
        }
        if replaceNotes(notes) { setSelection(Set(notes.map(\.id))) }
    }

    @discardableResult
    func replaceNotes(_ notes: [MelodyNote], reportError: Bool = true) -> Bool {
        guard let track = activeTrack, let index = project.tracks.firstIndex(where: { $0.id == track.id }) else { return false }
        let ids = Set(notes.map(\.id))
        var updated = project
        updated.tracks[index].notes.removeAll { ids.contains($0.id) }
        updated.tracks[index].notes += notes
        guard updated.tracks[index].isValid(limit: project.steps) else {
            if reportError { errorMessage = "音符会重叠或超出曲尾，请调整位置后重试。" }
            return false
        }
        update(updated)
        return true
    }

    func transposeSelection(by semitones: Int) {
        guard let track = activeTrack, !selectedIDs.isEmpty else { return }
        let notes = track.notes.filter { selectedIDs.contains($0.id) }.map { note in
            var updated = note
            updated.pitch += semitones
            return updated
        }
        _ = replaceNotes(notes)
    }

    func updateExpression(_ expression: NoteExpression, noteID: UUID, trackID: UUID) {
        guard activeTrack?.id == trackID, let track = activeTrack,
              var note = track.notes.first(where: { $0.id == noteID }), expression.isValid else { return }
        note.expression = expression
        _ = place(note)
    }

    func setLyric(_ text: String) {
        guard var note = selected else { return }
        note.lyric = String(text.prefix(12))
        note.expression.slur = false
        place(note, lyricEdit: note.id)
    }

    func applyBatchLyrics(_ replacements: [UUID: String], to track: MelodyTrack, in projectID: UUID) {
        guard currentProject?.id == projectID, activeTrack == track,
              let index = project.tracks.firstIndex(where: { $0.id == track.id }),
              Set(replacements.keys).isSubset(of: Set(track.notes.map(\.id))) else {
            errorMessage = "工程或音轨已更新，请重新预览批量歌词。"
            return
        }

        var updated = project
        for noteIndex in track.notes.indices {
            if let lyric = replacements[track.notes[noteIndex].id] {
                updated.tracks[index].notes[noteIndex].lyric = lyric
                updated.tracks[index].notes[noteIndex].expression.slur = false
            }
        }
        update(updated)
    }

    func finishLyricEdit() {
        lyricEditNote = nil
    }

    func deleteSelected() {
        guard !selectedIDs.isEmpty, let track = activeTrack,
              let index = project.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        var updated = project
        updated.tracks[index].notes.removeAll { selectedIDs.contains($0.id) }
        update(updated)
        clearSelection()
    }

    func setTempo(_ tempo: Int) {
        var updated = project
        updated.tempo = min(MelodyProject.tempos.upperBound, max(MelodyProject.tempos.lowerBound, tempo))
        update(updated)
    }

    private var editSnapshot: EditSnapshot {
        EditSnapshot(project: project, selectedID: selectedID, selectedIDs: selectedIDs,
                     activeTrackID: activeTrack?.id, entryStep: entryStep)
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
        activeTrackID = snapshot.activeTrackID ?? project.tracks.first?.id
        setSelection(snapshot.selectedIDs, primary: snapshot.selectedID)
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
        moveEntryCursor(to: entryStep)
        transportStep = min(project.steps - 1, transportStep)
        saveStatus = nil
        invalidateAudio()
        autosaveTask?.cancel()
        autosaveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                autosaveTask = nil
                try ProjectLibrary.save(active)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "旋律保存失败。\(error.localizedDescription)"
            }
        }
    }

    func flushAutosave() {
        guard let autosaveTask, let currentProject else { return }
        autosaveTask.cancel()
        self.autosaveTask = nil
        do {
            try ProjectLibrary.save(currentProject)
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

    func renderedAudio(window: Range<Int>? = nil, trackID: UUID? = nil) async -> Data? {
        guard !isBusy, let projectID = currentProject?.id else { return nil }
        let request = RenderRequest(window: window, trackID: trackID)
        if let cache, cache.request == request { return cache.data }
        guard let bank else {
            errorMessage = StudioError.noVoicebank.localizedDescription
            return nil
        }
        let snapshot = project
        isRendering = true
        let task = Task.detached(priority: .userInitiated) {
            try MelodyAudio.render(snapshot, bank: bank, window: window, trackID: trackID)
        }
        renderTask = task
        defer {
            isRendering = false
            renderTask = nil
        }
        do {
            let data = try await task.value
            guard currentProject?.id == projectID, project == snapshot, self.bank?.id == bank.id else { return nil }
            if data.count <= 32 * 1_048_576 { cache = (request, data) }
            return data
        } catch is CancellationError {
            return nil
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
        let window = loops ? project.loopRegion?.ticks : nil
        let region = window ?? 0..<project.steps
        guard let data = await renderedAudio(window: window), window == (loops ? project.loopRegion?.ticks : nil) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = loops ? -1 : 0
            player.currentTime = transportTime(duration: player.duration, region: region)
            player.delegate = self
            previewPlayer?.stop()
            guard player.play() else { throw StudioError.playback }
            songPlayer = player
            playingRegion = region
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        songPlayer?.stop()
        songPlayer = nil
        playingRegion = nil
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
        renderTask?.cancel()
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
