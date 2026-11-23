import SwiftUI
import UniformTypeIdentifiers

@main
struct MelodySketchApp: App {
    var body: some Scene {
        WindowGroup { StudioView() }
    }
}

private struct WaveDocument: FileDocument {
    static let waveType = UTType(filenameExtension: "wav") ?? .audio
    static var readableContentTypes: [UTType] { [waveType] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct StudioView: View {
    @StateObject private var model = StudioModel()
    @State private var tool = PianoRollTool.select
    @State private var snap = GridSnap.sixteenth
    @FocusState private var editingLyric: Bool
    @State private var keyboardExpanded = false
    @State private var keyboardMode = PianoKeyboardMode.audition
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: WaveDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            editorTools
            noteInspector
            PianoRoll(model: model, showsEntryCursor: keyboardExpanded && keyboardMode == .entry, tool: tool, snap: snap)
                .frame(minHeight: 180)
                .layoutPriority(1)
            PianoKeyboard(isExpanded: $keyboardExpanded, mode: $keyboardMode, location: model.entryLocation) { pitch in
                if model.isPlaying { model.stop() }
                if keyboardMode == .entry { model.enterNote(pitch: pitch) }
                model.audition(pitch: pitch)
            }
        }
        .padding(18)
        .foregroundStyle(Color.white)
        .background(Color(red: 0.07, green: 0.11, blue: 0.15).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(PianoRoll.accent)
        .onChange(of: editingLyric) { _, editing in
            if !editing { model.finishLyricEdit() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                Task { await model.importZIP(url) }
            case .failure(let error):
                if (error as NSError).code != CocoaError.Code.userCancelled.rawValue {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: WaveDocument.waveType, defaultFilename: "旋律草稿") { result in
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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
    }

    private var title: some View {
        Text("旋律草稿")
            .font(.system(size: 34, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var voicebankControls: some View {
        HStack(spacing: 12) {
            if model.isImporting {
                ProgressView("正在导入音源").controlSize(.small)
            } else if let bank = model.bank {
                Label("\(bank.samples.count)个日语音节", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Link("下载官方音源", destination: URL(string: "https://kasaneteto.jp/utau/")!)
            }
            Button(model.bank == nil ? "导入音源 ZIP" : "更换音源", systemImage: "tray.and.arrow.down") {
                showImporter = true
            }
            .buttonStyle(.bordered)
            .disabled(model.isImporting || model.isRendering)
        }
        .font(.subheadline)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { transport; Spacer(minLength: 8); tempo }
            VStack(alignment: .leading, spacing: 8) { transport; tempo }
        }
        .padding(12)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button("回到开头", systemImage: "backward.end.fill") {
                model.seek(to: 0)
                if keyboardExpanded && keyboardMode == .entry { model.moveEntryCursor(to: 0) }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)

            Button(model.isPlaying ? "停止" : "Teto唱一遍", systemImage: model.isPlaying ? "stop.fill" : "play.fill") {
                Task { await model.sing() }
            }
            .buttonStyle(.borderedProminent)
            .tint(PianoRoll.accent)
            .foregroundStyle(.black)
            .disabled(model.isImporting || model.isRendering)

            Toggle(isOn: $model.loops) {
                Label("循环", systemImage: "repeat")
            }
            .toggleStyle(.button)

            Button("导出 WAV", systemImage: "square.and.arrow.up") {
                Task {
                    guard let wave = await model.renderedAudio() else { return }
                    exportDocument = WaveDocument(data: wave)
                    showExporter = true
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRendering || model.isImporting)

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
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    private var toolPicker: some View {
        Picker("编辑工具", selection: $tool) {
            Text("选择").tag(PianoRollTool.select)
            Text("画笔").tag(PianoRollTool.draw)
        }
        .pickerStyle(.segmented)
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
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
    }

    private var snapPicker: some View {
        HStack(spacing: 8) {
            Text("网格吸附")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("网格吸附", selection: $snap) {
                ForEach(GridSnap.allCases, id: \.self) { resolution in
                    Text("1/\(16 / resolution.rawValue)").tag(resolution)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
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
                .textFieldStyle(.roundedBorder)
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
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minHeight: 36)
    }

    private func move(_ key: WritableKeyPath<MelodyNote, Int>, by offset: Int) {
        guard var note = model.selected else { return }
        note[keyPath: key] += offset
        if model.place(note), key == \MelodyNote.pitch { model.audition(pitch: note.pitch) }
    }
}
