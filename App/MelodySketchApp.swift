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
    let onExportWave: () -> Void
    @State private var tool = PianoRollTool.select
    @State private var snap = GridSnap.sixteenth
    @FocusState private var editingLyric: Bool
    @State private var keyboardExpanded = false
    @State private var keyboardMode = PianoKeyboardMode.audition

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
                        .frame(width: 210)
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
                if keyboardExpanded && keyboardMode == .entry { model.moveEntryCursor(to: 0) }
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

            Button("导出 WAV", systemImage: "square.and.arrow.up", action: onExportWave)
                .buttonStyle(StudioButtonStyle())
                .disabled(model.isBusy)

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
                Spacer(minLength: 10)
                snapPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { toolPicker; historyButtons }
                snapPicker
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .studioPanel(radius: 12)
    }

    private var toolPicker: some View {
        StudioSegments(
            selection: $tool, label: "编辑工具",
            options: [(PianoRollTool.select, "选择"), (PianoRollTool.draw, "画笔")]
        )
        .frame(width: 144)
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

    private var snapPicker: some View {
        HStack(spacing: 8) {
            Text("网格吸附")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
            StudioSegments(
                selection: $snap, label: "网格吸附",
                options: GridSnap.allCases.map { ($0, "1/\(16 / $0.rawValue)") }
            )
            .frame(width: 156)
        }
        .fixedSize()
    }

    private var noteInspector: some View {
        HStack(spacing: 12) {
            if let note = model.selected {
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
                Stepper("音高", onIncrement: { move(.pitch, by: 1) }, onDecrement: { move(.pitch, by: -1) })
                    .fixedSize()
                Stepper("时值", onIncrement: { move(.length, by: 1) }, onDecrement: { move(.length, by: -1) })
                    .fixedSize()
                Spacer(minLength: 0)
                Button("删除音符", systemImage: "trash", role: .destructive) { model.deleteSelected() }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("删除音符")
            } else {
                Text(tool == .select ? "点选音符编辑。点上方时间尺定位播放。" : "点空白网格添加音符，拖动可设置时值。")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                Spacer()
            }
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 4)
    }

    private func move(_ key: WritableKeyPath<MelodyNote, Int>, by offset: Int) {
        guard var note = model.selected else { return }
        note[keyPath: key] += offset
        if model.place(note), key == \MelodyNote.pitch { model.audition(pitch: note.pitch) }
    }
}
