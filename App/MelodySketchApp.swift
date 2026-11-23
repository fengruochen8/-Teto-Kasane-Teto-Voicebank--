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
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: WaveDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            noteInspector
            PianoRoll(model: model)
                .frame(minHeight: 250)
                .layoutPriority(1)
        }
        .padding(18)
        .foregroundStyle(Color.white)
        .background(Color(red: 0.07, green: 0.11, blue: 0.15).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(PianoRoll.accent)
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
                Text("点格子加音符。拖动音符改位置，拖右端改时值。")
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
