import SwiftUI

@main
struct MelodySketchApp: App {
    var body: some Scene {
        WindowGroup { ProjectWorkspace() }
    }
}

@MainActor
struct StudioView: View {
    @ObservedObject var model: StudioModel
    let onNew: () -> Void
    let onOpen: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onImportVoicebank: () -> Void
    let onExportWave: (UUID?) -> Void
    let onImportArrangement: () -> Void
    let onExportArrangement: (ProjectInterchange) -> Void
    @State private var tool = PianoRollTool.select
    @State private var snap = GridSnap.sixteenth
    @FocusState private var editingLyric: Bool
    @State private var keyboardExpanded = false
    @State private var keyboardMode = PianoKeyboardMode.audition
    @State private var batchLyricsRequest: BatchLyricsRequest?
    @State private var expressionRequest: ExpressionRequest?
    @State private var editingLength = false
    @State private var draftLength = 4

    private struct ExpressionRequest: Identifiable {
        let note: MelodyNote
        let trackID: UUID
        let canSlur: Bool

        var id: UUID { note.id }
    }

    private struct BatchLyricsRequest: Identifiable {
        let projectID: UUID
        let track: MelodyTrack
        let selectedID: UUID?
        let entryStep: Int
        let availableSamples: Set<String>?

        var id: UUID { track.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            editorTools
            noteInspector
            trackWorkspace.layoutPriority(1)
            PianoKeyboard(isExpanded: $keyboardExpanded, mode: $keyboardMode, location: model.entryLocation) { pitch in
                if model.isPlaying { model.stop() }
                if keyboardMode == .entry { model.enterNote(pitch: pitch) }
                model.audition(pitch: pitch)
            }
        }
        .padding(18)
        .foregroundStyle(StudioTheme.ink)
        .background(StudioTheme.backdrop.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .sheet(item: $batchLyricsRequest) { request in
            BatchLyricsSheet(
                track: request.track, selectedID: request.selectedID, entryStep: request.entryStep,
                availableSamples: request.availableSamples
            ) { replacements in
                model.applyBatchLyrics(replacements, to: request.track, in: request.projectID)
            }
        }
        .sheet(item: $expressionRequest) { request in
            NoteExpressionSheet(trackID: request.trackID, note: request.note, canSlur: request.canSlur) { expression in
                model.updateExpression(expression, noteID: request.note.id, trackID: request.trackID)
            }
        }
        .onChange(of: editingLyric) { _, editing in
            if !editing { model.finishLyricEdit() }
        }
    }

    @ViewBuilder
    private var trackWorkspace: some View {
        if let track = model.activeTrack {
            let roll = PianoRoll(
                model: model, trackID: track.id, showsEntryCursor: keyboardExpanded && keyboardMode == .entry,
                tool: tool, snap: snap
            )
            .id(track.id)
            .frame(minHeight: 180)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    TrackPanel(model: model)
                        .frame(width: 224)
                    roll.frame(minWidth: 420)
                }
                VStack(spacing: 10) {
                    TrackPanel(model: model, compact: true)
                    roll
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                title
                Spacer(minLength: 20)
                voicebankControls
            }
            VStack(alignment: .leading, spacing: 10) {
                title
                voicebankControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .studioPanel(radius: 16)
    }

    private var title: some View {
        HStack(spacing: 10) {
            Button("返回首页", systemImage: "house", action: model.showWelcome)
                .buttonStyle(StudioButtonStyle())
                .labelStyle(.iconOnly)
                .disabled(model.isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentProject?.document.name ?? "旋律草稿")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                if let status = model.saveStatus {
                    Text(status).font(.caption).foregroundStyle(StudioTheme.muted)
                }
            }
            Menu {
                Button("新建工程", systemImage: "plus", action: onNew)
                Button("打开工程", systemImage: "folder", action: onOpen)
                Button("另存为", systemImage: "doc.on.doc", action: onSaveAs)
                Divider()
                Button("导入 MIDI／UST／USTX", systemImage: "tray.and.arrow.down", action: onImportArrangement)
                Menu {
                    Button("MIDI（全部音轨）") { onExportArrangement(.midi) }
                    Button("UST（当前音轨）") { onExportArrangement(.ust) }
                    Button("USTX（全部音轨）") { onExportArrangement(.ustx) }
                } label: {
                    Label("导出乐谱", systemImage: "square.and.arrow.up")
                }
                .disabled(model.project.noteCount == 0)
            } label: {
                Label("工程", systemImage: "doc")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .studioPanel(radius: 10)
            }
            .disabled(model.isBusy)
            Button("保存", systemImage: "square.and.arrow.down", action: onSave)
                .buttonStyle(StudioButtonStyle())
                .disabled(model.isBusy)
        }
    }

    private var voicebankControls: some View {
        HStack(spacing: 12) {
            if model.isImporting {
                ProgressView("正在导入音源").controlSize(.small)
            } else if let bank = model.bank {
                Label("\(bank.samples.count)个日语音节", systemImage: "checkmark.circle")
                    .foregroundStyle(StudioTheme.muted)
            } else {
                Link("下载官方音源", destination: URL(string: "https://kasaneteto.jp/utau/")!)
            }
            Button(model.bank == nil ? "导入音源 ZIP" : "更换音源",
                   systemImage: "tray.and.arrow.down", action: onImportVoicebank)
                .buttonStyle(StudioButtonStyle())
                .disabled(model.isBusy)
        }
        .font(.subheadline)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { transport; Spacer(minLength: 8); tempo }
            VStack(alignment: .leading, spacing: 8) { transport; tempo }
        }
        .padding(10)
        .studioPanel(radius: 14)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button("回到开头", systemImage: "backward.end.fill") {
                model.seek(to: 0)
                model.moveEntryCursor(to: 0)
            }
            .buttonStyle(StudioButtonStyle())
            .labelStyle(.iconOnly)

            Button(model.isPlaying ? "停止" : "Teto唱一遍", systemImage: model.isPlaying ? "stop.fill" : "play.fill") {
                Task { await model.sing() }
            }
            .buttonStyle(StudioButtonStyle(prominent: true))
            .disabled(model.isBusy)

            Toggle(isOn: $model.loops) {
                Label("循环", systemImage: "repeat")
            }
            .toggleStyle(.button)

            Menu {
                Button("导出混音 WAV", systemImage: "waveform") { onExportWave(nil) }
                if let track = model.activeTrack {
                    Button("导出「\(track.name)」WAV", systemImage: "music.note") { onExportWave(track.id) }
                        .disabled(track.notes.isEmpty)
                }
            } label: {
                Label("导出 WAV", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .studioPanel(radius: 10)
            }
            .disabled(model.isBusy || model.project.noteCount == 0)

            if model.isRendering { ProgressView("合成中").controlSize(.small) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .controlSize(.large)
    }

    private var tempo: some View {
        Stepper(value: Binding(
            get: { model.project.tempo },
            set: { model.setTempo($0) }
        ), in: MelodyProject.tempos) {
            Text("\(model.project.tempo) BPM").monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var editorTools: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                toolPicker
                historyButtons
                batchLyricsButton
                editMenu
                Spacer(minLength: 8)
                timelineMenu
                snapPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    toolPicker
                    historyButtons
                    editMenu
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        batchLyricsButton
                        timelineMenu
                        snapPicker
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 12) {
                            batchLyricsButton
                            timelineMenu
                        }
                        snapPicker
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .studioPanel(radius: 12)
    }

    private var toolPicker: some View {
        StudioSegments(
            selection: $tool, label: "编辑工具",
            options: [(PianoRollTool.select, "选择"), (.draw, "画笔"), (.box, "框选"), (.pan, "移动")]
        )
        .frame(width: 206)
    }

    private var historyButtons: some View {
        HStack(spacing: 6) {
            Button("撤销", systemImage: "arrow.uturn.backward") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button("重做", systemImage: "arrow.uturn.forward") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
        .buttonStyle(StudioButtonStyle())
        .labelStyle(.iconOnly)
    }

    private var batchLyricsButton: some View {
        Button("批量歌词", systemImage: "text.alignleft") {
            guard let projectID = model.currentProject?.id, let track = model.activeTrack else { return }
            editingLyric = false
            model.finishLyricEdit()
            batchLyricsRequest = BatchLyricsRequest(
                projectID: projectID, track: track, selectedID: model.selectedID, entryStep: model.entryStep,
                availableSamples: model.bank.map { Set($0.samples.keys) }
            )
        }
        .buttonStyle(StudioButtonStyle())
        .disabled(model.isBusy || model.activeTrack?.notes.isEmpty != false)
    }

    private var snapPicker: some View {
        HStack(spacing: 8) {
            Text("网格吸附")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
            StudioSegments(
                selection: $snap, label: "网格吸附",
                options: GridSnap.allCases.map { ($0, $0.label) }
            )
            .frame(width: 156)
        }
        .fixedSize()
    }

    private var editMenu: some View {
        Menu {
            Button("复制音符", systemImage: "doc.on.doc", action: model.copySelection)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(model.selectedIDs.isEmpty)
            Button("粘贴到录入光标", systemImage: "clipboard", action: model.pasteNotes)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!model.hasCopiedNotes)
            Menu {
                Button("升高半音") { model.transposeSelection(by: 1) }
                Button("降低半音") { model.transposeSelection(by: -1) }
                Button("升高八度") { model.transposeSelection(by: 12) }
                Button("降低八度") { model.transposeSelection(by: -12) }
            } label: {
                Label("移调", systemImage: "arrow.up.and.down")
            }
            .disabled(model.selectedIDs.isEmpty)
            Button("删除选中音符", systemImage: "trash", role: .destructive, action: model.deleteSelected)
                .disabled(model.selectedIDs.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 38, height: 38)
                .studioPanel(radius: 9)
                .accessibilityLabel("音符编辑菜单")
        }
    }

    private var timelineMenu: some View {
        Menu {
            Button("追加4小节", systemImage: "plus") {
                model.resizeProject(to: min(MelodyProject.maxBars, model.project.barCount + 4))
            }
            .disabled(model.project.barCount >= MelodyProject.maxBars)
            Button("设置小节数", systemImage: "ruler") {
                draftLength = model.project.barCount
                editingLength = true
            }
            if let loop = model.project.loopRegion {
                Button("清除第\(loop.firstBar + 1)至\(loop.endBar)小节循环", systemImage: "repeat", action: model.clearLoop)
            }
        } label: {
            Label("\(model.project.barCount)小节", systemImage: "ruler")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 7)
                .frame(minHeight: 38)
                .studioPanel(radius: 9)
                .lineLimit(1)
        }
        .popover(isPresented: $editingLength) {
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: $draftLength, in: 1...MelodyProject.maxBars) {
                    Text("\(draftLength)小节").monospacedDigit()
                }
                HStack {
                    Button("取消") { editingLength = false }
                    Spacer()
                    Button("应用") {
                        editingLength = false
                        model.resizeProject(to: draftLength)
                    }
                    .buttonStyle(StudioButtonStyle(prominent: true))
                }
            }
            .padding(18)
            .frame(minWidth: 240)
        }
    }

    private var noteInspector: some View {
        HStack(spacing: 12) {
            if model.selectedIDs.count > 1 {
                Text("已选\(model.selectedIDs.count)个音符")
                    .font(.subheadline.weight(.semibold))
                Button("复制", systemImage: "doc.on.doc", action: model.copySelection)
                    .buttonStyle(StudioButtonStyle())
                Spacer(minLength: 0)
            } else if let note = model.selected {
                Text(MelodyProject.noteName(note.pitch))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .frame(minWidth: 44)
                TextField("假名", text: Binding(
                    get: { model.selected?.lyric ?? "" },
                    set: { model.setLyric($0) }
                ))
                .textFieldStyle(.plain)
                .foregroundStyle(StudioTheme.ink)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                .focused($editingLyric)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("音符假名")
                .frame(width: 104)
                .id(note.id)
                .disabled(note.expression.slur)
                Stepper("音高", onIncrement: { move(\MelodyNote.pitch, by: 1) }, onDecrement: { move(\MelodyNote.pitch, by: -1) })
                    .fixedSize()
                Stepper("时值", onIncrement: { move(\MelodyNote.length, by: snap.rawValue) }, onDecrement: { move(\MelodyNote.length, by: -snap.rawValue) })
                    .fixedSize()
                Button("调校", systemImage: "waveform.path") {
                    guard let track = model.activeTrack else { return }
                    editingLyric = false
                    expressionRequest = ExpressionRequest(note: note, trackID: track.id, canSlur: model.canSlurSelectedNote)
                }
                .buttonStyle(StudioButtonStyle())
                Spacer(minLength: 0)
                Button("删除音符", systemImage: "trash", role: .destructive) { model.deleteSelected() }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("删除音符")
            } else {
                Text(toolHint)
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                Spacer()
            }
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 4)
    }

    private var toolHint: String {
        switch tool {
        case .select: return "点选音符编辑，拖动时间尺设置循环。"
        case .draw: return "点空白网格添加音符，拖动设置时值。"
        case .box: return "在网格上拖出范围，框选多个音符。"
        case .pan: return "拖动浏览旋律，双指缩放时间轴。"
        }
    }

    private func move(_ key: WritableKeyPath<MelodyNote, Int>, by offset: Int) {
        guard var note = model.selected else { return }
        note[keyPath: key] += offset
        if key == \.length { note.length = max(1, note.length) }
        if model.place(note), key == \MelodyNote.pitch { model.audition(pitch: note.pitch) }
    }
}
