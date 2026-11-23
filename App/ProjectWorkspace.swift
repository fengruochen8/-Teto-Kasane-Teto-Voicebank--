import SwiftUI
import UIKit
import UniformTypeIdentifiers

private extension UTType {
    static let tetoProject = UTType(exportedAs: "com.fengruochen8.tetomelody.project", conformingTo: .json)
    static let wavAudio = UTType(filenameExtension: "wav") ?? .audio
    static let midiArrangement = UTType(filenameExtension: "mid") ?? UTType(importedAs: "public.midi-audio", conformingTo: .audio)
    static let ustArrangement = UTType(importedAs: "com.fengruochen8.tetomelody.ust", conformingTo: .plainText)
    static let ustxArrangement = UTType(importedAs: "com.fengruochen8.tetomelody.ustx", conformingTo: .plainText)
}

private extension ProjectInterchange {
    var contentType: UTType {
        switch self {
        case .midi: return .midiArrangement
        case .ust: return .ustArrangement
        case .ustx: return .ustxArrangement
        }
    }

    init?(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "mid", "midi": self = .midi
        case "ust": self = .ust
        case "ustx": self = .ustx
        default: return nil
        }
    }
}

private struct WorkspaceFile: FileDocument {
    static var readableContentTypes: [UTType] {
        [.tetoProject, .wavAudio] + ProjectInterchange.allCases.map(\.contentType)
    }
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
struct ProjectWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = StudioModel()
    @State private var isNamingProject = false
    @State private var isImportingFile = false
    @State private var isExportingFile = false
    @State private var inputKind = ImportKind.project
    @State private var exportRequest: ExportRequest?

    private enum ImportKind {
        case project
        case voicebank
        case arrangement

        var types: [UTType] {
            switch self {
            case .project: return [.tetoProject]
            case .voicebank: return [.zip]
            case .arrangement: return ProjectInterchange.allCases.map(\.contentType)
            }
        }
    }

    private struct ExportRequest {
        let file: WorkspaceFile
        let type: UTType
        let filename: String
        let projectID: UUID?
    }

    var body: some View {
        Group {
            if let record = model.currentProject {
                StudioView(
                    model: model,
                    onNew: { isNamingProject = true },
                    onOpen: { chooseFile(.project) },
                    onSave: { saveProject(asCopy: false) },
                    onSaveAs: { saveProject(asCopy: true) },
                    onImportVoicebank: { chooseFile(.voicebank) },
                    onExportWave: { trackID in Task { await exportWave(trackID: trackID) } },
                    onImportArrangement: { chooseFile(.arrangement) },
                    onExportArrangement: { format in Task { await exportArrangement(format) } }
                )
                .id(record.id)
            } else {
                WelcomeView(
                    projects: model.recentProjects,
                    onNew: { isNamingProject = true },
                    onOpen: { chooseFile(.project) },
                    onImportArrangement: { chooseFile(.arrangement) },
                    onExample: { model.createProject(named: "示例旋律", melody: .example) },
                    onRecent: { model.openLocalProject($0) }
                )
            }
        }
        .disabled(model.isHandlingProjectFile)
        .overlay {
            if model.isHandlingProjectFile {
                ProgressView("正在处理工程…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .preferredColorScheme(.dark)
        .tint(PianoRoll.accent)
        .task { model.loadProjectLibrary() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.flushAutosave() }
        }
        .sheet(isPresented: $isNamingProject) {
            NewProjectSheet { model.createProject(named: $0) }
                .presentationDetents([.height(225)])
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: inputKind.types, onCompletion: finishImport)
        .fileExporter(
            isPresented: $isExportingFile, document: exportRequest?.file,
            contentType: exportRequest?.type ?? .tetoProject,
            defaultFilename: exportRequest?.filename,
            onCompletion: finishExport
        )
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "tetomelody" {
                Task { await model.openExternalProject(url) }
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
        .alert("乐谱已导入", isPresented: Binding(
            get: { model.importNotice != nil },
            set: { if !$0 { model.importNotice = nil } }
        )) {
            Button("好", role: .cancel) { model.importNotice = nil }
        } message: {
            Text(model.importNotice ?? "")
        }
    }

    private func chooseFile(_ kind: ImportKind) {
        guard !model.isBusy else { return }
        inputKind = kind
        isImportingFile = true
    }

    private func finishImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            switch inputKind {
            case .project:
                Task { await model.openExternalProject(url) }
            case .voicebank:
                Task { await model.importZIP(url) }
            case .arrangement:
                guard let format = ProjectInterchange(fileURL: url) else {
                    model.errorMessage = "请选择 MIDI、UST 或 USTX 乐谱。"
                    return
                }
                Task { await model.importArrangement(url, format: format) }
            }
        case .failure(let error):
            showFileError(error)
        }
    }

    private func saveProject(asCopy: Bool) {
        guard !model.isBusy, let record = model.currentProject else { return }
        if !asCopy, model.canSaveToSource {
            Task { await model.saveToSource() }
            return
        }
        do {
            let data = try record.document.encoded()
            exportRequest = ExportRequest(
                file: WorkspaceFile(data: data), type: .tetoProject,
                filename: filename(record.document.name), projectID: record.id
            )
            isExportingFile = true
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func exportWave(trackID: UUID?) async {
        guard let record = model.currentProject,
              let data = await model.renderedAudio(trackID: trackID) else { return }
        let suffix = record.document.melody.tracks.first { $0.id == trackID }?.name ?? "混音"
        exportRequest = ExportRequest(
            file: WorkspaceFile(data: data), type: .wavAudio,
            filename: filename("\(record.document.name) - \(suffix)"), projectID: nil
        )
        isExportingFile = true
    }

    private func exportArrangement(_ format: ProjectInterchange) async {
        guard let record = model.currentProject, let data = await model.exportArrangement(format) else { return }
        exportRequest = ExportRequest(
            file: WorkspaceFile(data: data), type: format.contentType,
            filename: filename(record.document.name) + "." + format.fileExtension, projectID: nil
        )
        isExportingFile = true
    }

    private func finishExport(_ result: Result<URL, Error>) {
        let completed = exportRequest
        exportRequest = nil
        switch result {
        case .success(let url):
            if let projectID = completed?.projectID {
                model.recordProjectExport(to: url, projectID: projectID)
            }
        case .failure(let error):
            showFileError(error)
        }
    }

    private func showFileError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != CocoaError.Code.userCancelled.rawValue {
            model.errorMessage = error.localizedDescription
        }
    }

    private func filename(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: separators).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "旋律草稿" : cleaned
    }
}

@MainActor
private struct WelcomeView: View {
    private static let officialArt = UIImage(named: "TetoWelcomeIllustration")

    let projects: [LocalProject]
    let onNew: () -> Void
    let onOpen: () -> Void
    let onImportArrangement: () -> Void
    let onExample: () -> Void
    let onRecent: (LocalProject) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { newCard; openCard; importCard }
                    VStack(spacing: 12) { newCard; openCard; importCard }
                }
                recent
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 34)
            .frame(maxWidth: 1_040)
            .frame(maxWidth: .infinity)
        }
        .background(StudioTheme.backdrop.ignoresSafeArea())
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                heroCopy
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(32)
                heroIllustration
                    .frame(minWidth: 330, maxWidth: .infinity)
                    .frame(height: 288)
                    .clipped()
            }
            .frame(minHeight: 288)

            VStack(alignment: .leading, spacing: 0) {
                heroCopy
                    .padding(26)
                heroIllustration
                    .frame(height: 188)
                    .clipped()
            }
        }
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.78), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: StudioTheme.backgroundTop.opacity(0.38), radius: 24, y: 12)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("旋律草稿")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(StudioTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("为重音Teto编写旋律")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(StudioTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heroIllustration: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [StudioTheme.surface, StudioTheme.raised, Color(red: 0.32, green: 0.13, blue: 0.25)],
                startPoint: .leading,
                endPoint: .trailing
            )
            RadialGradient(
                colors: [StudioTheme.accent.opacity(0.24), .clear],
                center: .trailing,
                startRadius: 5,
                endRadius: 240
            )
            if let officialArt = Self.officialArt {
                GeometryReader { geometry in
                    let artHeight = geometry.size.height * 2.35
                    Image(uiImage: officialArt)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * 0.88, height: artHeight)
                        .position(x: geometry.size.width * 0.60, y: artHeight / 2 + 6)
                        .accessibilityHidden(true)
                }
                Text("重音テト © 線／小山乃舞世／TWINDRILL")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(StudioTheme.background.opacity(0.90), in: Capsule())
                    .padding(10)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 49, weight: .light))
                    .foregroundStyle(StudioTheme.secondary.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
    }

    private var newCard: some View {
        actionCard("新建工程", detail: "从空白旋律开始", icon: "plus", highlighted: true, action: onNew)
    }

    private var openCard: some View {
        actionCard("打开工程", detail: "从「文件」打开 .tetomelody", icon: "folder", highlighted: false, action: onOpen)
    }

    private var importCard: some View {
        actionCard("导入乐谱", detail: "MIDI、UST 或 USTX", icon: "tray.and.arrow.down", highlighted: false, action: onImportArrangement)
    }

    private func actionCard(_ title: String, detail: String, icon: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(highlighted ? StudioTheme.background : StudioTheme.secondary)
                    .frame(width: 44, height: 44)
                    .background(highlighted ? StudioTheme.accent : StudioTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(StudioTheme.ink)
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StudioTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(highlighted ? StudioTheme.accent : StudioTheme.muted)
            }
            .frame(minWidth: 214, maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                highlighted ? StudioTheme.raised : StudioTheme.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(highlighted ? StudioTheme.accent.opacity(0.72) : StudioTheme.border.opacity(0.84))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近工程")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(StudioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("打开示例", systemImage: "music.note", action: onExample)
                    .buttonStyle(StudioButtonStyle())
            }
            if projects.isEmpty {
                Text("新建或打开的工程会显示在这里。")
                    .foregroundStyle(StudioTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(StudioTheme.border, lineWidth: 1).allowsHitTesting(false) }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(projects) { record in
                        Button { onRecent(record) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(StudioTheme.accent)
                                    .frame(width: 34, height: 34)
                                    .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.document.name).font(.headline).foregroundStyle(StudioTheme.ink).lineLimit(1)
                                    Text("\(record.document.melody.barCount)小节 · \(record.document.melody.tracks.count)条音轨 · \(record.document.melody.tempo) BPM")
                                        .font(.subheadline).foregroundStyle(StudioTheme.muted)
                                }
                                Spacer(minLength: 4)
                                Text(record.updatedAt, format: .dateTime.month().day())
                                    .font(.subheadline).foregroundStyle(StudioTheme.muted)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(StudioTheme.muted)
                            }
                            .padding(14)
                            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StudioTheme.border.opacity(0.82), lineWidth: 1).allowsHitTesting(false) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

@MainActor
private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                StudioTheme.backdrop.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Label("工程名称", systemImage: "music.note.list")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(StudioTheme.secondary)
                    TextField("未命名工程", text: $name)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StudioTheme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StudioTheme.border, lineWidth: 1).allowsHitTesting(false) }
                    Text("工程会保存在本机，可随时导出为.tetomelody文件。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StudioTheme.muted)
                }
                .padding(22)
                .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(StudioTheme.border, lineWidth: 1).allowsHitTesting(false) }
                .padding(20)
            }
            .navigationTitle("新建工程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: create)
                }
            }
        }
        .tint(StudioTheme.accent)
        .onAppear { titleFocused = true }
    }

    private func create() {
        onCreate(name)
        dismiss()
    }
}
